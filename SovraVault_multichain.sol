// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SovraVault — Multi-Chain Edition
 * @notice Sovra Protocol — Sovereign bond yield on-chain
 * @dev Compatible with all EVM chains:
 *      Ethereum, Base, Arbitrum, Optimism, Polygon,
 *      BNB Chain, Mantra, Plume, Celo, Scroll
 *
 * Deploy one instance per vault type:
 *   svNG  baseAprBps=2000  fxRate=135000  fxSymbol=NGN
 *   svTR  baseAprBps=2700  fxRate=4500    fxSymbol=TRY
 *   svAR  baseAprBps=4000  fxRate=140000  fxSymbol=ARS
 *
 * Two modes:
 *   TESTNET  — uses MockUSDC with mint() for self-funding
 *   MAINNET  — uses real USDC, owner pre-funds yield reserve
 *
 * Fees:
 *   Immediate exit  : 5%   principal + 10% yield -> treasury
 *   10-day notice   : 2.5% principal + 10% yield -> treasury
 *   Matured         : 0%   principal + 10% yield -> treasury
 */

// ─────────────────────────────────────────────
// INTERFACES
// ─────────────────────────────────────────────

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IMockUSDC is IERC20 {
    function mint(address to, uint256 amount) external;
}

// ─────────────────────────────────────────────
// MAIN CONTRACT
// ─────────────────────────────────────────────

contract SovraVault {

    // ── ERC-20 (svToken) ──────────────────────
    string  public name;
    string  public symbol;
    uint8   public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ── Protocol State ────────────────────────
    address   public owner;
    address   public protocolTreasury;
    address   public usdcAddress;
    bool      public isTestnet;         // true = MockUSDC mint mode
    uint256   public baseAprBps;        // base APR in basis points
    uint256   public fxRate;            // FX rate (scaled x100 for decimals)
    string    public fxSymbol;          // e.g. "NGN", "TRY", "ARS"
    uint256   public totalDeposited;
    uint256   public yieldReserve;      // mainnet: manually funded yield pool
    bool      public paused;            // emergency pause

    // ── Constants ─────────────────────────────
    uint256 public constant YIELD_FEE_BPS      = 1000;  // 10%
    uint256 public constant IMMEDIATE_EXIT_BPS = 500;   // 5%
    uint256 public constant NOTICE_EXIT_BPS    = 250;   // 2.5%
    uint256 public constant NOTICE_PERIOD      = 10 days;
    uint256 public constant MAX_DEPOSIT        = 1_000_000 * 1e6; // 1M USDC cap per position

    // ── Lock Period Multipliers ───────────────
    // Multiplier out of 10000 applied to baseAprBps
    mapping(uint256 => uint256) public lockMultipliers;

    // ── Position ──────────────────────────────
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

    // ── Events ────────────────────────────────
    event Deposited(
        address indexed user,
        uint256 principal,
        uint256 lockDays,
        uint256 effectiveAprBps,
        uint256 yieldReserved
    );
    event NoticeGiven(address indexed user, uint256 withdrawableFrom);
    event Redeemed(
        address indexed user,
        uint256 principal,
        uint256 grossYield,
        uint256 yieldFee,
        uint256 principalPenalty,
        uint256 netReceived,
        uint8   exitType        // 0=matured, 1=notice, 2=immediate
    );
    event FxRateUpdated(uint256 oldRate, uint256 newRate);
    event YieldReserveFunded(uint256 amount, uint256 newTotal);
    event Paused(bool status);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // ─────────────────────────────────────────
    // CONSTRUCTOR
    // ─────────────────────────────────────────

    /**
     * @param _usdc         USDC contract address on this chain
     * @param _treasury     Protocol treasury address
     * @param _name         svToken name e.g. "Sovra Nigeria Vault"
     * @param _symbol       svToken symbol e.g. "svNG"
     * @param _baseAprBps   Base APR in bps e.g. 2000 = 20%
     * @param _fxRate       FX rate scaled x100 e.g. 135000 = 1350 NGN/USDC
     * @param _fxSymbol     FX symbol e.g. "NGN"
     * @param _isTestnet    true for testnet (MockUSDC mint), false for mainnet
     */
    constructor(
        address _usdc,
        address _treasury,
        string memory _name,
        string memory _symbol,
        uint256 _baseAprBps,
        uint256 _fxRate,
        string memory _fxSymbol,
        bool _isTestnet
    ) {
        require(_usdc != address(0),     "Invalid USDC address");
        require(_treasury != address(0), "Invalid treasury address");
        require(_baseAprBps > 0,         "APR must be > 0");
        require(_fxRate > 0,             "FX rate must be > 0");

        owner            = msg.sender;
        protocolTreasury = _treasury;
        usdcAddress      = _usdc;
        name             = _name;
        symbol           = _symbol;
        baseAprBps       = _baseAprBps;
        fxRate           = _fxRate;
        fxSymbol         = _fxSymbol;
        isTestnet        = _isTestnet;

        // Lock period multipliers (% of baseApr applied)
        lockMultipliers[30]  = 8000;   // 80% of base APR
        lockMultipliers[60]  = 8500;   // 85%
        lockMultipliers[90]  = 9000;   // 90%
        lockMultipliers[180] = 9500;   // 95%
        lockMultipliers[365] = 10000;  // 100% (full APR)
    }

    // ─────────────────────────────────────────
    // MODIFIERS
    // ─────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier notPaused() {
        require(!paused, "Protocol paused");
        _;
    }

    // ─────────────────────────────────────────
    // CORE FUNCTIONS
    // ─────────────────────────────────────────

    /**
     * @notice Deposit USDC and lock for yield
     * @param usdcAmount Amount of USDC to deposit (6 decimals)
     * @param lockDays   Lock period: 30, 60, 90, 180, or 365
     */
    function deposit(uint256 usdcAmount, uint256 lockDays) external notPaused {
        require(usdcAmount > 0,                       "Amount must be > 0");
        require(usdcAmount <= MAX_DEPOSIT,            "Exceeds max deposit");
        require(lockMultipliers[lockDays] > 0,        "Invalid lock period");
        require(positions[msg.sender].principal == 0, "Close existing position first");

        IERC20 usdc = IERC20(usdcAddress);
        require(usdc.transferFrom(msg.sender, address(this), usdcAmount), "USDC transfer failed");

        uint256 effectiveAprBps = (baseAprBps * lockMultipliers[lockDays]) / 10000;
        uint256 maxYield = (usdcAmount * effectiveAprBps * lockDays) / (10000 * 365);

        // Testnet: mint yield from MockUSDC
        // Mainnet: check yield reserve has enough
        if (isTestnet) {
            IMockUSDC(usdcAddress).mint(address(this), maxYield);
        } else {
            require(yieldReserve >= maxYield, "Insufficient yield reserve — owner must fund");
            yieldReserve -= maxYield;
        }

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

    /**
     * @notice Give 10-day notice to exit early with reduced penalty
     */
    function giveNotice() external notPaused {
        Position storage pos = positions[msg.sender];
        require(pos.principal > 0,      "No active position");
        require(pos.noticeGivenAt == 0, "Notice already given");
        require(block.timestamp < pos.depositTime + pos.lockSeconds, "Already matured — just redeem");
        pos.noticeGivenAt = block.timestamp;
        emit NoticeGiven(msg.sender, block.timestamp + NOTICE_PERIOD);
    }

    /**
     * @notice Redeem position — get principal + yield back
     */
    function redeem() external notPaused {
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
            exitType = 0; // No principal penalty
        } else if (pos.noticeGivenAt > 0 && block.timestamp >= pos.noticeGivenAt + NOTICE_PERIOD) {
            principalPenalty = (pos.principal * NOTICE_EXIT_BPS) / 10000;
            exitType = 1;
        } else if (pos.noticeGivenAt > 0) {
            revert("Notice period not complete — wait 10 days");
        } else {
            principalPenalty = (pos.principal * IMMEDIATE_EXIT_BPS) / 10000;
            exitType = 2;
        }

        uint256 netReceived = (pos.principal - principalPenalty) + netYield;
        uint256 totalFees   = yieldFee + principalPenalty;

        // Unused yield goes back to reserve on mainnet
        uint256 unusedYield = pos.maxYield > grossYield ? pos.maxYield - grossYield : 0;
        if (!isTestnet && unusedYield > 0) {
            yieldReserve += unusedYield;
        }

        _burn(msg.sender, balanceOf[msg.sender]);
        totalDeposited -= pos.principal;
        delete positions[msg.sender];

        IERC20 usdc = IERC20(usdcAddress);
        require(usdc.transfer(msg.sender, netReceived),        "Transfer to user failed");
        if (totalFees > 0) {
            require(usdc.transfer(protocolTreasury, totalFees), "Transfer to treasury failed");
        }

        emit Redeemed(msg.sender, pos.principal, grossYield, yieldFee, principalPenalty, netReceived, exitType);
    }

    // ─────────────────────────────────────────
    // VIEW FUNCTIONS
    // ─────────────────────────────────────────

    /**
     * @notice Get full position details for a user
     */
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
        bool _locked = pos.principal > 0 && block.timestamp < pos.depositTime + pos.lockSeconds;
        uint256 _daysLeft = 0;
        if (_locked) {
            uint256 unlock = pos.depositTime + pos.lockSeconds;
            if (block.timestamp < unlock) _daysLeft = (unlock - block.timestamp) / 86400;
        }
        uint256 elapsed = pos.principal > 0 ? block.timestamp - pos.depositTime : 0;
        uint256 _yield  = (pos.principal * pos.effectiveAprBps * elapsed) / (10000 * 365 days);
        if (_yield > pos.maxYield) _yield = pos.maxYield;

        return (
            pos.principal,
            pos.depositTime,
            pos.lockDays,
            pos.effectiveAprBps,
            _yield,
            _locked,
            _daysLeft,
            pos.noticeGivenAt > 0,
            pos.noticeGivenAt > 0 ? pos.noticeGivenAt + NOTICE_PERIOD : 0
        );
    }

    /**
     * @notice Get current yield earned for a user
     */
    function getYieldEarned(address user) external view returns (uint256) {
        Position memory pos = positions[user];
        if (pos.principal == 0) return 0;
        uint256 elapsed = block.timestamp - pos.depositTime;
        uint256 y = (pos.principal * pos.effectiveAprBps * elapsed) / (10000 * 365 days);
        return y > pos.maxYield ? pos.maxYield : y;
    }

    /**
     * @notice Get vault USDC balance
     */
    function vaultUsdcBalance() external view returns (uint256) {
        return IERC20(usdcAddress).balanceOf(address(this));
    }

    /**
     * @notice Calculate effective APR for a given lock period
     */
    function getEffectiveApr(uint256 lockDays) external view returns (uint256) {
        return (baseAprBps * lockMultipliers[lockDays]) / 10000;
    }

    /**
     * @notice Preview yield for a deposit amount and lock period
     */
    function previewYield(uint256 usdcAmount, uint256 lockDays) external view returns (
        uint256 effectiveAprBps,
        uint256 maxYield,
        uint256 netYield
    ) {
        uint256 apr = (baseAprBps * lockMultipliers[lockDays]) / 10000;
        uint256 gross = (usdcAmount * apr * lockDays) / (10000 * 365);
        uint256 fee = (gross * YIELD_FEE_BPS) / 10000;
        return (apr, gross, gross - fee);
    }

    // ─────────────────────────────────────────
    // OWNER FUNCTIONS
    // ─────────────────────────────────────────

    /**
     * @notice Fund yield reserve (mainnet only)
     */
    function fundYieldReserve(uint256 amount) external onlyOwner {
        require(!isTestnet, "Not needed on testnet");
        require(IERC20(usdcAddress).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        yieldReserve += amount;
        emit YieldReserveFunded(amount, yieldReserve);
    }

    function setFxRate(uint256 newRate) external onlyOwner {
        require(newRate > 0, "Rate must be > 0");
        emit FxRateUpdated(fxRate, newRate);
        fxRate = newRate;
    }

    function setTreasury(address t) external onlyOwner {
        require(t != address(0), "Invalid address");
        protocolTreasury = t;
    }

    function setBaseApr(uint256 newAprBps) external onlyOwner {
        require(newAprBps > 0 && newAprBps <= 10000, "Invalid APR");
        baseAprBps = newAprBps;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ─────────────────────────────────────────
    // ERC-20 FUNCTIONS (svToken)
    // ─────────────────────────────────────────

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "Insufficient allowance");
            allowance[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply    += amount;
        balanceOf[to]  += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        totalSupply     -= amount;
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0),          "Transfer to zero address");
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
    }
}
