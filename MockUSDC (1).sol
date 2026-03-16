// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockUSDC
 * @notice Testnet USDC — anyone can mint free tokens for testing Sovra Protocol
 */
contract MockUSDC {

    string  public name     = "USD Coin";
    string  public symbol   = "USDC";
    uint8   public decimals = 6;          // Real USDC uses 6 decimals
    uint256 public totalSupply;

    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ── Faucet ──────────────────────────────────────────────────────────────
    // Anyone can call this to get 10,000 USDC for testing
    uint256 public constant FAUCET_AMOUNT = 10_000 * 1e6; // 10,000 USDC

    function faucet() external {
        _mint(msg.sender, FAUCET_AMOUNT);
    }

    // Owner can also mint arbitrary amounts
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "Not owner");
        _mint(to, amount);
    }

    // ── ERC-20 ───────────────────────────────────────────────────────────────
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

    // ── Internal ─────────────────────────────────────────────────────────────
    function _mint(address to, uint256 amount) internal {
        totalSupply       += amount;
        balanceOf[to]     += amount;
        emit Transfer(address(0), to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
    }
}
