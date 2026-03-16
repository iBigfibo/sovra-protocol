// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SovraVault v2
 * @notice Tokenised emerging-market T-Bill vault — Sovra Protocol (Testnet)
 *
 * Deploy once per vault:
 *   svNG  baseAprBps=2000  fxRate=158000  (NGN: 1,580 per $1, stored as 1580 * 100)
 *   svTR  baseAprBps=2700  fxRate=3600    (TRY: 36 per $1, stored as 36 * 100)
 *   svAR  baseAprBps=4000  fxRate=105000  (ARS: 1,050 per $1, stored as 1050 * 100)
 *
 * Fee & Penalty Model:
 *   - Immediate early exit   : 5%   of principal  +  10% of yield  -> protocol
 *   - 10-day notice exit     : 2.5% of principal  +  10% of yield  -> protocol
 *   - Matured (lock expired) : 0%   on principal  +  10% of yield  -> protocol
 *
 * Lock tiers & APR multipliers:
 *   30d  -> 80%  of baseApr
 *   60d  -> 85%  of baseApr
 *   90d  -> 90%  of baseApr
 *   180d -> 95%  of baseApr
 *   365d -> 100% of baseApr
 *
 * Yield = principal x effectiveAPR x secondsElapsed / secondsInYear
 */

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract SovraVault {

    // ── Token (svToken receipt) ───────────────────────────────────────────────
    string  public name;
    string  public symbol;
    uint8   public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ── Config ────────────────────────────────────────────────────────────────
    address public owner;
    address public protocolTreasury;   // receives all fees & penalties
    IERC20  public usdc;
    uint256 public baseAprBps;         // e.g. 2000 = 20.00%
    uint256 public fxRate;             // local currency per $1, scaled x100 (e.g. NGN 1580.00 = 158000)
    string  public fxSymbol;           // e.g. "NGN"
    uint256 public totalDeposited;

    uint256 public constant YIELD_FEE_BPS      = 1000;  // 10% of yield -> protocol
    uint256 public constant IMMEDIATE_EXIT_BPS = 500;   // 5%   of principal -> protocol
    uint256 public constant NOTICE_EXIT_BPS    = 250;   // 2.5% of principal -> protocol
    uint256 public constant NOTICE_PERIOD      = 10 days;

    struct LockTier {
        uint256 aprMultiplierBps;  // e.g. 8000 = 80%
    }
    mapping(uint256 => LockTier) public lockTiers;

    // ── Position ──────────────────────────────────────────────────────────────
    struct Position {
        uint256 principal;
        uint256 depositTime;
        uint256 lockDays;
        uint256 lockSeconds;
        uint256 effectiveAprBps;
        uint256 noticeGivenAt;    // 0 = no notice given yet
    }
    mapping(address => Position) public positions;

    // ── Events ────────────────────────────────────────────────────────────────
    event Deposited(address indexed user, uint256 principal, uint256 lockDays, uint256 effectiveAprBps);
    event NoticeGiven(address indexed user, uint256 noticeTime, uint256 withdrawableFrom);
    event Redeemed(
        address indexed user,
        uint256 principal,
        uint256 grossYield,
        uint256 yieldFee,
        uint256 principalPenalty,
        uint256 netReceived,
        uint8   exitType   // 0=matured, 1=notice, 2=immediate
    );
    event FxRateUpdated(uint256 oldRate, uint256 newRate);
    event YieldFunded(address indexed funder, uint256 amount);

    // ── Constructor ───────────────────────────────────────────────────────────
    constructor(
        address _usdc,
        address _treasury,
        string memory _name,
        string memory _symbol,
        uint256 _baseAprBps,
        uint256 _fxRate,
        string memory _fxSymbol
    ) {
        owner             = msg.sender;
        protocolTreasury  = _treasury;
        usdc              = IERC20(_usdc);
        name              = _name;
        symbol            = _symbol;
        baseAprBps        = _baseAprBps;
        fxRate            = _fxRate;
        fxSymbol          = _fxSymbol;

        lockTiers[30]  = LockTier({ aprMultiplierBps: 8000  });
        lockTiers[60]  = LockTier({ aprMultiplierBps: 8500  });
        lockTiers[90]  = LockTier({ aprMultiplierBps: 9000  });
        lockTiers[180] = LockTier({ aprMultiplierBps: 9500  });
        lockTiers[365] = LockTier({ aprMultiplierBps: 10000 });
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // ── Deposit ───────────────────────────────────────────────────────────────
    function deposit(uint256 usdcAmount, uint256 lockDays) external {
        require(usdcAmount > 0,                           "Amount must be > 0");
        require(lockTiers[lockDays].aprMultiplierBps > 0, "Invalid lock period");
        require(positions[msg.sender].principal == 0,     "Close existing position first");

        require(usdc.transferFrom(msg.sender, address(this), usdcAmount), "USDC transfer failed");

        uint256 effectiveAprBps = (baseAprBps * lockTiers[lockDays].aprMultiplierBps) / 10000;

        _mint(msg.sender, usdcAmount);

        positions[msg.sender] = Position({
            principal:        usdcAmount,
            depositTime:      block.timestamp,
            lockDays:         lockDays,
            lockSeconds:      lockDays * 86400,
            effectiveAprBps:  effectiveAprBps,
            noticeGivenAt:    0
        });

        totalDeposited += usdcAmount;
        emit Deposited(msg.sender, usdcAmount, lockDays, effectiveAprBps);
    }

    // ── Give Notice ───────────────────────────────────────────────────────────
    // User signals intent to withdraw early with reduced penalty.
    // Must wait NOTICE_PERIOD (10 days) before redeeming.
    function giveNotice() external {
        Position storage pos = positions[msg.sender];
        require(pos.principal > 0,       "No active position");
        require(pos.noticeGivenAt == 0,  "Notice already given");
        require(_isLocked(pos),          "Vault already matured - redeem directly");

        pos.noticeGivenAt = block.timestamp;
        emit NoticeGiven(msg.sender, block.timestamp, block.timestamp + NOTICE_PERIOD);
    }

    // ── Redeem ────────────────────────────────────────────────────────────────
    function redeem() external {
        Position memory pos = positions[msg.sender];
        require(pos.principal > 0, "No active position");

        uint256 grossYield = _calcYield(pos);
        uint256 yieldFee   = (grossYield * YIELD_FEE_BPS) / 10000;  // 10% of yield
        uint256 netYield   = grossYield - yieldFee;

        uint256 principalPenalty = 0;
        uint8   exitType;

        bool matured = !_isLocked(pos);

        if (matured) {
            // No principal penalty
            exitType = 0;
        } else if (pos.noticeGivenAt > 0 && block.timestamp >= pos.noticeGivenAt + NOTICE_PERIOD) {
            // 10-day notice served — 2.5% principal penalty
            principalPenalty = (pos.principal * NOTICE_EXIT_BPS) / 10000;
            exitType = 1;
        } else if (pos.noticeGivenAt > 0) {
            // Notice given but period not served yet
            revert("Notice period not complete - wait 10 days from notice");
        } else {
            // Immediate exit — 5% principal penalty
            principalPenalty = (pos.principal * IMMEDIATE_EXIT_BPS) / 10000;
            exitType = 2;
        }

        uint256 netPrincipal = pos.principal - principalPenalty;
        uint256 totalFees    = yieldFee + principalPenalty;
        uint256 netReceived  = netPrincipal + netYield;

        require(
            usdc.balanceOf(address(this)) >= netReceived + totalFees,
            "Insufficient vault reserves - contact owner"
        );

        uint256 svBalance = balanceOf[msg.sender];
        _burn(msg.sender, svBalance);
        totalDeposited -= pos.principal;
        delete positions[msg.sender];

        // Send net amount to user
        require(usdc.transfer(msg.sender, netReceived), "Transfer to user failed");

        // Send fees to protocol treasury
        if (totalFees > 0) {
            require(usdc.transfer(protocolTreasury, totalFees), "Transfer to treasury failed");
        }

        emit Redeemed(msg.sender, pos.principal, grossYield, yieldFee, principalPenalty, netReceived, exitType);
    }

    // ── Views ─────────────────────────────────────────────────────────────────
    function getPosition(address user) external view returns (
        uint256 principal,
        uint256 depositTime,
        uint256 lockDays,
        uint256 effectiveAprBps,
        uint256 yieldEarned,
        bool    locked,
        uint256 daysLeft,
        bool    noticeGiven,
        uint256 noticeReadyAt
    ) {
        Position memory pos = positions[user];
        bool _locked = _isLocked(pos);
        uint256 _daysLeft = 0;
        if (_locked) {
            uint256 unlock = pos.depositTime + pos.lockSeconds;
            if (block.timestamp < unlock) {
                _daysLeft = (unlock - block.timestamp) / 86400;
            }
        }
        bool _noticeGiven = pos.noticeGivenAt > 0;
        uint256 _noticeReadyAt = _noticeGiven ? pos.noticeGivenAt + NOTICE_PERIOD : 0;

        return (
            pos.principal,
            pos.depositTime,
            pos.lockDays,
            pos.effectiveAprBps,
            _calcYield(pos),
            _locked,
            _daysLeft,
            _noticeGiven,
            _noticeReadyAt
        );
    }

    function getYieldEarned(address user) external view returns (uint256) {
        return _calcYield(positions[user]);
    }

    function getRedemptionPreview(address user) external view returns (
        uint256 grossYield,
        uint256 yieldFee,
        uint256 principalPenalty,
        uint256 netReceived,
        uint8   exitType,
        bool    canRedeem
    ) {
        Position memory pos = positions[user];
        if (pos.principal == 0) return (0, 0, 0, 0, 0, false);

        grossYield = _calcYield(pos);
        yieldFee   = (grossYield * YIELD_FEE_BPS) / 10000;

        bool matured = !_isLocked(pos);

        if (matured) {
            principalPenalty = 0;
            exitType  = 0;
            canRedeem = true;
        } else if (pos.noticeGivenAt > 0 && block.timestamp >= pos.noticeGivenAt + NOTICE_PERIOD) {
            principalPenalty = (pos.principal * NOTICE_EXIT_BPS) / 10000;
            exitType  = 1;
            canRedeem = true;
        } else if (pos.noticeGivenAt > 0) {
            principalPenalty = (pos.principal * NOTICE_EXIT_BPS) / 10000;
            exitType  = 1;
            canRedeem = false; // notice given but period not up
        } else {
            principalPenalty = (pos.principal * IMMEDIATE_EXIT_BPS) / 10000;
            exitType  = 2;
            canRedeem = true;
        }

        netReceived = (pos.principal - principalPenalty) + (grossYield - yieldFee);
    }

    function fxEquivalent(uint256 usdcAmount) external view returns (uint256) {
        // usdcAmount is in 6 decimals, fxRate is scaled x100
        // returns local currency amount scaled x100 (divide by 100 for display)
        return (usdcAmount * fxRate) / 1e6;
    }

    function vaultUsdcBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    // ── Owner functions ───────────────────────────────────────────────────────
    function fundYieldReserves(uint256 amount) external onlyOwner {
        require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        emit YieldFunded(msg.sender, amount);
    }

    function setFxRate(uint256 newRate) external onlyOwner {
        emit FxRateUpdated(fxRate, newRate);
        fxRate = newRate;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Zero address");
        protocolTreasury = newTreasury;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    // ── ERC-20 ────────────────────────────────────────────────────────────────
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "Allowance exceeded");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    // ── Internal ──────────────────────────────────────────────────────────────
    function _isLocked(Position memory pos) internal view returns (bool) {
        if (pos.principal == 0) return false;
        return block.timestamp < pos.depositTime + pos.lockSeconds;
    }

    function _calcYield(Position memory pos) internal view returns (uint256) {
        if (pos.principal == 0) return 0;
        uint256 elapsed = block.timestamp - pos.depositTime;
        return (pos.principal * pos.effectiveAprBps * elapsed) / (10000 * 365 days);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply   += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "Burn exceeds balance");
        balanceOf[from] -= amount;
        totalSupply     -= amount;
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
    }
}
