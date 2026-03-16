// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SovraVault v4
 * @notice Sovra Protocol Testnet - Self-funding vault
 *
 * On every deposit the vault calls usdc.mint(address(this), maxYield)
 * to pre-fund the exact yield needed. No manual fundReserves needed.
 * MockUSDC must have this vault whitelisted via addMinter.
 *
 * svNG  baseAprBps=2000  fxRate=135000  fxSymbol=NGN
 * svTR  baseAprBps=2700  fxRate=4500    fxSymbol=TRY
 * svAR  baseAprBps=4000  fxRate=140000  fxSymbol=ARS
 *
 * Fees:
 *   Immediate exit  : 5%   principal + 10% yield -> treasury
 *   10-day notice   : 2.5% principal + 10% yield -> treasury
 *   Matured         : 0%   principal + 10% yield -> treasury
 */

interface IMockUSDC {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
}

contract SovraVault {

    string  public name;
    string  public symbol;
    uint8   public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    address   public owner;
    address   public protocolTreasury;
    IMockUSDC public usdc;
    uint256   public baseAprBps;
    uint256   public fxRate;
    string    public fxSymbol;
    uint256   public totalDeposited;

    uint256 public constant YIELD_FEE_BPS      = 1000;
    uint256 public constant IMMEDIATE_EXIT_BPS = 500;
    uint256 public constant NOTICE_EXIT_BPS    = 250;
    uint256 public constant NOTICE_PERIOD      = 10 days;

    mapping(uint256 => uint256) public lockMultipliers;

    struct Position {
        uint256 principal;
        uint256 depositTime;
        uint256 lockDays;
        uint256 lockSeconds;
        uint256 effectiveAprBps;
        uint256 maxYield;
        uint256 noticeGivenAt;
    }
    mapping(address => Position) public positions;

    event Deposited(address indexed user, uint256 principal, uint256 lockDays, uint256 effectiveAprBps, uint256 yieldReserved);
    event NoticeGiven(address indexed user, uint256 withdrawableFrom);
    event Redeemed(address indexed user, uint256 principal, uint256 grossYield, uint256 yieldFee, uint256 principalPenalty, uint256 netReceived, uint8 exitType);
    event FxRateUpdated(uint256 oldRate, uint256 newRate);

    constructor(
        address _usdc,
        address _treasury,
        string memory _name,
        string memory _symbol,
        uint256 _baseAprBps,
        uint256 _fxRate,
        string memory _fxSymbol
    ) {
        owner            = msg.sender;
        protocolTreasury = _treasury;
        usdc             = IMockUSDC(_usdc);
        name             = _name;
        symbol           = _symbol;
        baseAprBps       = _baseAprBps;
        fxRate           = _fxRate;
        fxSymbol         = _fxSymbol;
        lockMultipliers[30]  = 8000;
        lockMultipliers[60]  = 8500;
        lockMultipliers[90]  = 9000;
        lockMultipliers[180] = 9500;
        lockMultipliers[365] = 10000;
    }

    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    function deposit(uint256 usdcAmount, uint256 lockDays) external {
        require(usdcAmount > 0,                       "Amount must be > 0");
        require(lockMultipliers[lockDays] > 0,        "Invalid lock period");
        require(positions[msg.sender].principal == 0, "Close existing position first");
        require(usdc.transferFrom(msg.sender, address(this), usdcAmount), "USDC transfer failed");

        uint256 effectiveAprBps = (baseAprBps * lockMultipliers[lockDays]) / 10000;
        uint256 maxYield = (usdcAmount * effectiveAprBps * lockDays) / (10000 * 365);

        usdc.mint(address(this), maxYield);
        _mint(msg.sender, usdcAmount);

        positions[msg.sender] = Position({
            principal:       usdcAmount,
            depositTime:     block.timestamp,
            lockDays:        lockDays,
            lockSeconds:     lockDays * 86400,
            effectiveAprBps: effectiveAprBps,
            maxYield:        maxYield,
            noticeGivenAt:   0
        });

        totalDeposited += usdcAmount;
        emit Deposited(msg.sender, usdcAmount, lockDays, effectiveAprBps, maxYield);
    }

    function giveNotice() external {
        Position storage pos = positions[msg.sender];
        require(pos.principal > 0,      "No active position");
        require(pos.noticeGivenAt == 0, "Notice already given");
        require(block.timestamp < pos.depositTime + pos.lockSeconds, "Already matured");
        pos.noticeGivenAt = block.timestamp;
        emit NoticeGiven(msg.sender, block.timestamp + NOTICE_PERIOD);
    }

    function redeem() external {
        Position memory pos = positions[msg.sender];
        require(pos.principal > 0, "No active position");

        uint256 elapsed    = block.timestamp - pos.depositTime;
        uint256 grossYield = (pos.principal * pos.effectiveAprBps * elapsed) / (10000 * 365 days);
        if (grossYield > pos.maxYield) grossYield = pos.maxYield;

        uint256 yieldFee = (grossYield * YIELD_FEE_BPS) / 10000;
        uint256 netYield = grossYield - yieldFee;

        uint256 principalPenalty = 0;
        uint8   exitType;
        bool    matured = block.timestamp >= pos.depositTime + pos.lockSeconds;

        if (matured) {
            exitType = 0;
        } else if (pos.noticeGivenAt > 0 && block.timestamp >= pos.noticeGivenAt + NOTICE_PERIOD) {
            principalPenalty = (pos.principal * NOTICE_EXIT_BPS) / 10000;
            exitType = 1;
        } else if (pos.noticeGivenAt > 0) {
            revert("Notice period not complete - wait 10 days");
        } else {
            principalPenalty = (pos.principal * IMMEDIATE_EXIT_BPS) / 10000;
            exitType = 2;
        }

        uint256 netReceived = (pos.principal - principalPenalty) + netYield;
        uint256 totalFees   = yieldFee + principalPenalty;

        _burn(msg.sender, balanceOf[msg.sender]);
        totalDeposited -= pos.principal;
        delete positions[msg.sender];

        require(usdc.transfer(msg.sender, netReceived), "Transfer to user failed");
        if (totalFees > 0) {
            require(usdc.transfer(protocolTreasury, totalFees), "Transfer to treasury failed");
        }

        emit Redeemed(msg.sender, pos.principal, grossYield, yieldFee, principalPenalty, netReceived, exitType);
    }

    function getPosition(address user) external view returns (
        uint256 principal, uint256 depositTime, uint256 lockDays,
        uint256 effectiveAprBps, uint256 yieldEarned, bool locked,
        uint256 daysLeft, bool noticeGiven, uint256 noticeReadyAt
    ) {
        Position memory pos = positions[user];
        bool _locked = pos.principal > 0 && block.timestamp < pos.depositTime + pos.lockSeconds;
        uint256 _days = 0;
        if (_locked) {
            uint256 unlock = pos.depositTime + pos.lockSeconds;
            if (block.timestamp < unlock) _days = (unlock - block.timestamp) / 86400;
        }
        uint256 elapsed = pos.principal > 0 ? block.timestamp - pos.depositTime : 0;
        uint256 _yield  = (pos.principal * pos.effectiveAprBps * elapsed) / (10000 * 365 days);
        if (_yield > pos.maxYield) _yield = pos.maxYield;
        return (pos.principal, pos.depositTime, pos.lockDays, pos.effectiveAprBps, _yield,
                _locked, _days, pos.noticeGivenAt > 0,
                pos.noticeGivenAt > 0 ? pos.noticeGivenAt + NOTICE_PERIOD : 0);
    }

    function getYieldEarned(address user) external view returns (uint256) {
        Position memory pos = positions[user];
        if (pos.principal == 0) return 0;
        uint256 elapsed = block.timestamp - pos.depositTime;
        uint256 y = (pos.principal * pos.effectiveAprBps * elapsed) / (10000 * 365 days);
        return y > pos.maxYield ? pos.maxYield : y;
    }

    function vaultUsdcBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function setFxRate(uint256 newRate) external onlyOwner {
        emit FxRateUpdated(fxRate, newRate); fxRate = newRate;
    }
    function setTreasury(address t) external onlyOwner { require(t != address(0)); protocolTreasury = t; }
    function transferOwnership(address n) external onlyOwner { require(n != address(0)); owner = n; }

    function transfer(address to, uint256 amount) external returns (bool) { _transfer(msg.sender, to, amount); return true; }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) { require(a >= amount); allowance[from][msg.sender] = a - amount; }
        _transfer(from, to, amount); return true;
    }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; emit Approval(msg.sender, s, a); return true; }

    function _mint(address to, uint256 a) internal { totalSupply += a; balanceOf[to] += a; emit Transfer(address(0), to, a); }
    function _burn(address f, uint256 a) internal { require(balanceOf[f] >= a); balanceOf[f] -= a; totalSupply -= a; emit Transfer(f, address(0), a); }
    function _transfer(address f, address t, uint256 a) internal { require(balanceOf[f] >= a); balanceOf[f] -= a; balanceOf[t] += a; emit Transfer(f, t, a); }
}
