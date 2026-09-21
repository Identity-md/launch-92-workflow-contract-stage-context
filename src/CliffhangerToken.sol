// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Cliffhanger (CLIF)
/// @notice Fixed-supply ERC-20. The entire supply of 1,000,000,000 CLIF (10^27 minor units) is minted
/// to the deployer in the constructor. There is no mint function, no owner, no admin, no pause and no
/// upgrade path: after construction the supply can never change.
contract CliffhangerToken {
    string public constant name = "Cliffhanger";
    string public constant symbol = "CLIF";
    uint8 public constant decimals = 18;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    uint256 public immutable totalSupply;

    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance(address account, uint256 balance, uint256 needed);
    error InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error InvalidReceiver(address receiver);
    error InvalidSpender(address spender);

    constructor() {
        totalSupply = TOTAL_SUPPLY;
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        if (spender == address(0)) revert InvalidSpender(spender);
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /// @dev An allowance of type(uint256).max is treated as infinite and is not decreased.
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance(msg.sender, allowed, value);
            unchecked {
                allowance[from][msg.sender] = allowed - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        if (to == address(0)) revert InvalidReceiver(to);
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert InsufficientBalance(from, fromBalance, value);
        unchecked {
            // Cannot overflow: the sum of all balances equals the fixed total supply.
            balanceOf[from] = fromBalance - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }
}
