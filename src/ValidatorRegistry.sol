// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {AccessControlManager} from "./AccessControlManager.sol";
import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";

/// @title ValidatorRegistry
/// @notice Manages general validator stakes. Validators stake once here to become active,
///         then can open/vote on many cases without re-locking tokens per transaction.
/// @dev    SLASHER_ROLE is held exclusively by VotingModule. Only VotingModule can
///         call slash(), incrementActiveVoteCount(), and decrementActiveVoteCount().
contract ValidatorRegistry is IValidatorRegistry, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Validator {
        uint256 stakedBalance;
        /// @dev Tracks open votes — must be 0 before unstake is allowed (anti-evasion)
        uint256 activeVoteCount;
    }

    IERC20 public immutable stakingToken;
    AccessControlManager public immutable accessControl;
    address public treasury;

    mapping(address => Validator) public validators;
    uint256 public minValidatorStake;

    event Staked(address indexed validator, uint256 amount, uint256 newBalance);
    event Unstaked(address indexed validator, uint256 amount, uint256 newBalance);
    event Slashed(address indexed validator, uint256 amount);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event MinStakeUpdated(uint256 oldMinStake, uint256 newMinStake);

    error ZeroAddress();
    error ZeroAmount();
    error HasActiveVotes();
    error InsufficientStake();

    constructor(
        address _stakingToken,
        address _accessControl,
        address _treasury,
        uint256 _minValidatorStake
    ) {
        if (_stakingToken == address(0) || _accessControl == address(0) || _treasury == address(0)) {
            revert ZeroAddress();
        }
        stakingToken = IERC20(_stakingToken);
        accessControl = AccessControlManager(_accessControl);
        treasury = _treasury;
        minValidatorStake = _minValidatorStake;
    }

    modifier onlyAdmin() {
        require(accessControl.hasRole(accessControl.ADMIN_ROLE(), msg.sender), "Not ADMIN_ROLE");
        _;
    }

    modifier onlySlasher() {
        require(accessControl.hasRole(accessControl.SLASHER_ROLE(), msg.sender), "Not SLASHER_ROLE");
        _;
    }

    function setMinStake(uint256 amount) external onlyAdmin {
        emit MinStakeUpdated(minValidatorStake, amount);
        minValidatorStake = amount;
    }

    function setTreasury(address _treasury) external onlyAdmin {
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    /// @notice Stake tokens to become an active validator.
    /// @dev    Follows CEI: Effects (state update) before Interactions (external call).
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        // Effects first
        validators[msg.sender].stakedBalance += amount;
        emit Staked(msg.sender, amount, validators[msg.sender].stakedBalance);
        // Interactions last — prevents read-only reentrancy via ERC777/hook tokens
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw staked tokens. Reverts if validator has active (unresolved) votes.
    /// @dev    Unstake evasion protection: activeVoteCount must be 0.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (validators[msg.sender].activeVoteCount > 0) revert HasActiveVotes();
        if (validators[msg.sender].stakedBalance < amount) revert InsufficientStake();
        // Effects
        validators[msg.sender].stakedBalance -= amount;
        emit Unstaked(msg.sender, amount, validators[msg.sender].stakedBalance);
        // Interactions
        stakingToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Slash a validator's staked balance and forward slashed tokens to Treasury.
    /// @dev    Only callable by VotingModule (SLASHER_ROLE). nonReentrant because it
    ///         performs a token transfer to Treasury at the end of execution.
    function slash(address validator, uint256 amount) external nonReentrant onlySlasher {
        uint256 slashable = validators[validator].stakedBalance;
        if (slashable == 0) return;
        // Cap slash at available balance
        uint256 actualAmount = amount > slashable ? slashable : amount;
        // Effects
        validators[validator].stakedBalance -= actualAmount;
        emit Slashed(validator, actualAmount);
        // Interactions — transfer slashed tokens to Treasury pool
        stakingToken.safeTransfer(treasury, actualAmount);
    }

    function isActive(address validator) external view returns (bool) {
        return validators[validator].stakedBalance >= minValidatorStake;
    }

    /// @dev Only VotingModule (SLASHER_ROLE) may call this to lock the validator's
    ///      stake during an active vote, preventing unstake evasion.
    function incrementActiveVoteCount(address validator) external onlySlasher {
        validators[validator].activeVoteCount += 1;
    }

    function decrementActiveVoteCount(address validator) external onlySlasher {
        require(validators[validator].activeVoteCount > 0, "Vote count underflow");
        validators[validator].activeVoteCount -= 1;
    }

    function stakedBalanceOf(address validator) external view returns (uint256) {
        return validators[validator].stakedBalance;
    }
}
