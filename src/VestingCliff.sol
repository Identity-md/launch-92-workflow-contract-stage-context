// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @title VestingCliff
/// @notice Irrevocable token vesting with a cliff.
/// A funder locks `amount` tokens for a beneficiary. The schedule starts at the block in which it is
/// created (`start`). Nothing is vested before `cliff`. From `cliff` on, the vested amount is
/// `amount * (now - start) / (end - start)`, reaching the full amount at `end`. The beneficiary may
/// claim whatever is vested and not yet claimed. No one — not the funder, not a deployer — can revoke,
/// pause or redirect a schedule. There is no owner, no fee and no upgradeability.
contract VestingCliff {
    struct Schedule {
        address funder;
        address beneficiary;
        uint64 start;
        uint64 cliff;
        uint64 end;
        uint256 amount;
        uint256 claimed;
    }

    /// @notice The only token this contract vests (CLIF), fixed at construction.
    IERC20Minimal public immutable token;

    /// @notice Schedules by id. Ids start at 0 and increase by one per schedule.
    Schedule[] private _schedules;
    mapping(address beneficiary => uint256[]) private _byBeneficiary;
    mapping(address funder => uint256[]) private _byFunder;

    /// @notice Sum of `amount - claimed` over all schedules; always equals what the contract owes.
    uint256 public totalLocked;

    uint256 private _lock = 1;

    event ScheduleCreated(
        uint256 indexed id,
        address indexed funder,
        address indexed beneficiary,
        uint256 amount,
        uint64 start,
        uint64 cliff,
        uint64 end
    );
    event Claimed(uint256 indexed id, address indexed beneficiary, uint256 amount);

    error InvalidToken();
    error ZeroAmount();
    error InvalidBeneficiary();
    error InvalidTimes();
    error UnknownSchedule(uint256 id);
    error NotBeneficiary(uint256 id, address caller);
    error NothingToClaim(uint256 id);
    error TransferFailed();
    error AmountMismatch(uint256 expected, uint256 received);
    error Reentrancy();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address token_) {
        if (token_.code.length == 0) revert InvalidToken();
        token = IERC20Minimal(token_);
    }

    /// @notice Lock `amount` tokens from the caller for `beneficiary`.
    /// @dev Caller must first approve this contract for `amount`. Requires
    /// `block.timestamp <= cliff <= end` and `end > block.timestamp`. `cliff == block.timestamp` is a
    /// schedule without a cliff; `cliff == end` releases everything at once at `end`.
    /// @return id The new schedule id.
    function createSchedule(address beneficiary, uint256 amount, uint64 cliff, uint64 end)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (amount == 0) revert ZeroAmount();
        if (beneficiary == address(0) || beneficiary == address(this)) revert InvalidBeneficiary();
        // casting to 'uint64' is safe because timestamps stay below 2^64 for billions of years
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 start = uint64(block.timestamp);
        if (cliff < start || end < cliff || end == start) revert InvalidTimes();

        id = _schedules.length;
        _schedules.push(
            Schedule({
                funder: msg.sender,
                beneficiary: beneficiary,
                start: start,
                cliff: cliff,
                end: end,
                amount: amount,
                claimed: 0
            })
        );
        _byBeneficiary[beneficiary].push(id);
        _byFunder[msg.sender].push(id);
        totalLocked += amount;
        emit ScheduleCreated(id, msg.sender, beneficiary, amount, start, cliff, end);

        uint256 before = token.balanceOf(address(this));
        _call(abi.encodeCall(IERC20Minimal.transferFrom, (msg.sender, address(this), amount)));
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert AmountMismatch(amount, received);
    }

    /// @notice Transfer everything currently claimable on schedule `id` to its beneficiary.
    /// @dev Only the beneficiary may call.
    /// @return amount The amount transferred.
    function claim(uint256 id) external nonReentrant returns (uint256 amount) {
        Schedule storage s = _get(id);
        if (msg.sender != s.beneficiary) revert NotBeneficiary(id, msg.sender);
        amount = _vested(s, block.timestamp) - s.claimed;
        if (amount == 0) revert NothingToClaim(id);

        s.claimed += amount;
        totalLocked -= amount;
        emit Claimed(id, msg.sender, amount);

        _call(abi.encodeCall(IERC20Minimal.transfer, (msg.sender, amount)));
    }

    // ---------------------------------------------------------------- views

    function scheduleCount() external view returns (uint256) {
        return _schedules.length;
    }

    function getSchedule(uint256 id) external view returns (Schedule memory) {
        return _get(id);
    }

    /// @notice Vested amount (claimed or not) of schedule `id` at the current time.
    function vestedAmount(uint256 id) external view returns (uint256) {
        return _vested(_get(id), block.timestamp);
    }

    /// @notice Vested amount of schedule `id` at an arbitrary `timestamp`.
    function vestedAmountAt(uint256 id, uint256 timestamp) external view returns (uint256) {
        return _vested(_get(id), timestamp);
    }

    /// @notice Amount the beneficiary of schedule `id` could claim right now.
    function claimableAmount(uint256 id) external view returns (uint256) {
        Schedule storage s = _get(id);
        return _vested(s, block.timestamp) - s.claimed;
    }

    function schedulesOfBeneficiary(address beneficiary) external view returns (uint256[] memory) {
        return _byBeneficiary[beneficiary];
    }

    function schedulesOfFunder(address funder) external view returns (uint256[] memory) {
        return _byFunder[funder];
    }

    // ------------------------------------------------------------- internal

    function _get(uint256 id) private view returns (Schedule storage) {
        if (id >= _schedules.length) revert UnknownSchedule(id);
        return _schedules[id];
    }

    function _vested(Schedule storage s, uint256 timestamp) private view returns (uint256) {
        if (timestamp < s.cliff) return 0;
        if (timestamp >= s.end) return s.amount;
        // start < end here (enforced at creation) and timestamp < end, so no division by zero and the
        // result is strictly below amount. amount <= token supply so the product cannot overflow for
        // CLIF; Solidity checked math reverts for any token where it would.
        return (s.amount * (timestamp - s.start)) / (s.end - s.start);
    }

    /// @dev Calls the token, accepting both bool-returning and no-return ERC-20 implementations.
    function _call(bytes memory data) private {
        (bool ok, bytes memory ret) = address(token).call(data);
        if (!ok || (ret.length != 0 && (ret.length != 32 || !abi.decode(ret, (bool))))) revert TransferFailed();
    }
}
