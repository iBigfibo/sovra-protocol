// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockUSDC — Sovra Protocol Testnet
 * @notice Fake USDC for testnet deployments on any EVM chain
 * @dev Deploy this first, then deploy SovraVault with this address
 *      Call addMinter(vaultAddress) after deploying each vault
 */
contract MockUSDC {

    string  public constant name     = "USD Coin";
    string  public constant symbol   = "USDC";
    uint8   public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public owner;
    mapping(address => bool) public minters;

    // Faucet config
    uint256 public constant FAUCET_AMOUNT   = 10_000 * 1e6; // 10,000 USDC
    uint256 public constant FAUCET_COOLDOWN = 24 hours;
    mapping(address => uint256) public lastFaucetTime;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);
    event FaucetUsed(address indexed user, uint256 amount);

    constructor() {
        owner = msg.sender;
        minters[msg.sender] = true;
        // Mint initial supply to deployer for testing
        _mint(msg.sender, 1_000_000 * 1e6); // 1M USDC
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyMinter() {
        require(minters[msg.sender], "Not a minter");
        _;
    }

    // ── Faucet ────────────────────────────────

    /**
     * @notice Claim 10,000 testnet USDC (once per 24 hours)
     */
    function faucet() external {
        require(
            block.timestamp >= lastFaucetTime[msg.sender] + FAUCET_COOLDOWN,
            "Faucet cooldown — come back in 24 hours"
        );
        lastFaucetTime[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
        emit FaucetUsed(msg.sender, FAUCET_AMOUNT);
    }

    /**
     * @notice Check if address can use faucet
     */
    function canUseFaucet(address user) external view returns (bool, uint256 secondsLeft) {
        if (block.timestamp >= lastFaucetTime[user] + FAUCET_COOLDOWN) {
            return (true, 0);
        }
        uint256 left = (lastFaucetTime[user] + FAUCET_COOLDOWN) - block.timestamp;
        return (false, left);
    }

    // ── Mint ─────────────────────────────────

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    // ── Minter Management ────────────────────

    function addMinter(address minter) external onlyOwner {
        minters[minter] = true;
        emit MinterAdded(minter);
    }

    function removeMinter(address minter) external onlyOwner {
        minters[minter] = false;
        emit MinterRemoved(minter);
    }

    // ── ERC-20 ───────────────────────────────

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

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        owner = newOwner;
    }

    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "Mint to zero address");
        totalSupply   += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0),          "Transfer to zero address");
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
    }
}
