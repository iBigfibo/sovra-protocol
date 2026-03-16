// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockUSDC v2
 * @notice Testnet USDC — anyone can faucet, whitelisted vaults can auto-mint yield reserves
 */
contract MockUSDC {

    string  public name     = "USD Coin";
    string  public symbol   = "USDC";
    uint8   public decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool)                        public isMinter; // vaults

    address public owner;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);

    constructor() {
        owner = msg.sender;
    }

    // ── Faucet — anyone gets 10,000 USDC ─────────────────────────────────────
    uint256 public constant FAUCET_AMOUNT = 10_000 * 1e6;

    function faucet() external {
        _mint(msg.sender, FAUCET_AMOUNT);
    }

    // ── Mint — owner or whitelisted vaults only ───────────────────────────────
    function mint(address to, uint256 amount) external {
        require(msg.sender == owner || isMinter[msg.sender], "Not authorised to mint");
        _mint(to, amount);
    }

    // ── Owner: manage minters ─────────────────────────────────────────────────
    function addMinter(address vault) external {
        require(msg.sender == owner, "Not owner");
        isMinter[vault] = true;
        emit MinterAdded(vault);
    }

    function removeMinter(address vault) external {
        require(msg.sender == owner, "Not owner");
        isMinter[vault] = false;
        emit MinterRemoved(vault);
    }

    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "Not owner");
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
            require(allowed >= amount, "Allowance too low");
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
    function _mint(address to, uint256 amount) internal {
        totalSupply   += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
    }
}
