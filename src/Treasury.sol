// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {AccessControlManager} from "./AccessControlManager.sol";

/// @title Treasury
/// @notice Holds the reward pool for validators. Slashed tokens flow here passively
///         via direct token transfers from ValidatorRegistry.slash().
///         This contract has NO ability to write to ValidatorRegistry — it only
///         allocates rewards (pull-based) from its own token balance.
contract Treasury is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;
    AccessControlManager public immutable accessControl;

    mapping(address => uint256) public pendingRewards;
    uint256 public totalPendingRewards;

    event Rewarded(address indexed validator, uint256 amount);
    event Claimed(address indexed validator, uint256 amount);
    event PoolFunded(address indexed funder, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientPool();
    error NoPendingRewards();

    constructor(address _stakingToken, address _accessControl) {
        if (_stakingToken == address(0) || _accessControl == address(0)) revert ZeroAddress();
        stakingToken = IERC20(_stakingToken);
        accessControl = AccessControlManager(_accessControl);
    }

    /// @notice Add tokens to the reward pool. Anyone can fund the pool (donations, protocol fees).
    ///         Slashed tokens from ValidatorRegistry also arrive here as passive transfers
    ///         and automatically increase the pool balance.
    function fundPool(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit PoolFunded(msg.sender, amount);
    }

    /// @notice Returns the amount of tokens available to allocate as new rewards.
    function getAvailablePool() public view returns (uint256) {
        return stakingToken.balanceOf(address(this)) - totalPendingRewards;
    }

    /// @notice Allocate a flat reward amount to a validator who voted with the majority.
    /// @dev    Only callable by VotingModule (SLASHER_ROLE). Does NOT touch ValidatorRegistry.
    ///         nonReentrant as defense-in-depth even though no external calls are made here.
    function reward(address validator, uint256 amount) external nonReentrant {
        require(accessControl.hasRole(accessControl.SLASHER_ROLE(), msg.sender), "Not SLASHER_ROLE");
        if (getAvailablePool() < amount) revert InsufficientPool();

        // Effects only — no external calls, token transfer happens in claim()
        pendingRewards[validator] += amount;
        totalPendingRewards += amount;
        emit Rewarded(validator, amount);
    }

    /// @notice Pull-based reward withdrawal. Validators claim their earned rewards.
    /// @dev    CEI: clears state before transfer.
    function claim() external nonReentrant {
        uint256 amount = pendingRewards[msg.sender];
        if (amount == 0) revert NoPendingRewards();

        // Effects
        pendingRewards[msg.sender] = 0;
        totalPendingRewards -= amount;
        emit Claimed(msg.sender, amount);
        // Interactions
        stakingToken.safeTransfer(msg.sender, amount);
    }
}
