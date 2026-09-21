// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Minimal, permissive ERC-20 used as a base for adversarial test tokens.
contract BaseMockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        _move(msg.sender, to, amount);
        _afterTransfer();
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        _afterTransfer();
        return true;
    }

    function _move(address from, address to, uint256 amount) internal virtual {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function _afterTransfer() internal virtual {}
}

/// @dev Re-enters a configurable target with configurable calldata on every transfer.
contract ReentrantToken is BaseMockToken {
    address public target;
    bytes public payload;
    bool public reentered;
    bool public reentrySucceeded;
    bytes public reentryRevertData;

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function _afterTransfer() internal override {
        if (target == address(0) || reentered) return;
        reentered = true;
        (bool ok, bytes memory ret) = target.call(payload);
        reentrySucceeded = ok;
        reentryRevertData = ret;
    }
}

/// @dev Takes a 1% fee on every transfer, so the recipient receives less than requested.
contract FeeOnTransferToken is BaseMockToken {
    function _move(address from, address to, uint256 amount) internal override {
        uint256 fee = amount / 100;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
    }
}

/// @dev Returns false instead of reverting, and moves nothing, once `failing` is set.
contract FalseReturningToken is BaseMockToken {
    bool public failing;

    function setFailing(bool f) external {
        failing = f;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        if (failing) return false;
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        if (failing) return false;
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }
}

/// @dev ERC-20 whose transfer functions return nothing (USDT-style).
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
