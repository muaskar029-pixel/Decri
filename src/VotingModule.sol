// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {AccessControlManager} from "./AccessControlManager.sol";
import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";
import {ICaseManager, Case, CaseStatus} from "../interfaces/ICaseManager.sol";
import {IRiskRegistry} from "../interfaces/IRiskRegistry.sol";
import {IVotingModule} from "../interfaces/IVotingModule.sol";

interface ITreasury {
    function reward(address validator, uint256 amount) external;
}

/// @title VotingModule
/// @notice Handles the full voting lifecycle: cast votes, resolve outcomes,
///         distribute flat rewards to majority and slash minority.
/// @dev    Holds SLASHER_ROLE in ValidatorRegistry and VOTING_ROLE in RiskRegistry.
///         SLASHER_ROLE also gates Treasury.reward() so no other party can inflate rewards.
contract VotingModule is IVotingModule, ReentrancyGuard {
    struct VoteTally {
        bytes32 targetHash;
        uint256 votesFor; // stake-weighted sum for "valid"
        uint256 votesAgainst; // stake-weighted sum for "invalid"
        uint256 startTime;
        bool resolved;
    }

    struct ValidatorVote {
        address validator;
        bool supportsValid;
        /// @dev Snapshot of validator's stakedBalance at vote time.
        ///      Used for stake-weighted tally (Sybil resistance), NOT for reward/slash size.
        uint256 weight;
    }

    AccessControlManager public immutable accessControl;
    IValidatorRegistry public immutable validatorRegistry;
    IRiskRegistry public immutable riskRegistry;
    ITreasury public immutable treasury;

    ICaseManager public caseManager;
    bool public caseManagerSet;

    mapping(bytes32 => VoteTally) public tallies;
    mapping(bytes32 => mapping(address => ValidatorVote)) public votes;
    mapping(bytes32 => address[]) public voterList;

    uint256 public quorumBps = 500; // 5% of total staked weight must participate
    uint256 public totalStakedWeight; // maintained on stake/unstake via events — set by admin for MVP
    uint256 public voteRewardAmount;
    uint256 public voteSlashAmount;

    /// @dev Hard DoS protection: cap max voters that can be processed in one resolveVote() call.
    uint256 public constant MAX_VOTERS_PER_RESOLVE = 500;

    event VoteCast(bytes32 indexed targetHash, address indexed validator, bool supportsValid, uint256 weight);
    event CaseResolved(bytes32 indexed targetHash, CaseStatus result);
    event QuorumUpdated(uint256 newBps);
    event RewardSlashAmountUpdated(uint256 rewardAmount, uint256 slashAmount);
    event TotalStakedWeightUpdated(uint256 newTotal);

    error ZeroAddress();
    error AlreadySet();
    error NotCaseManager();
    error AlreadyVoted();
    error NotActiveValidator();
    error CaseNotVoting();
    error VotingPeriodNotEnded();
    error AlreadyResolved();
    error TooManyVoters();
    error QuorumNotMet();

    constructor(
        address _accessControl,
        address _validatorRegistry,
        address _riskRegistry,
        address _treasury,
        uint256 _voteRewardAmount,
        uint256 _voteSlashAmount
    ) {
        if (
            _accessControl == address(0) || _validatorRegistry == address(0) || _riskRegistry == address(0)
                || _treasury == address(0)
        ) revert ZeroAddress();

        accessControl = AccessControlManager(_accessControl);
        validatorRegistry = IValidatorRegistry(_validatorRegistry);
        riskRegistry = IRiskRegistry(_riskRegistry);
        treasury = ITreasury(_treasury);
        voteRewardAmount = _voteRewardAmount;
        voteSlashAmount = _voteSlashAmount;
    }

    /// @notice Set the CaseManager address. Can only be called ONCE after deployment.
    function setCaseManager(address _caseManager) external {
        require(accessControl.hasRole(accessControl.ADMIN_ROLE(), msg.sender), "Not ADMIN_ROLE");
        if (_caseManager == address(0)) revert ZeroAddress();
        if (caseManagerSet) revert AlreadySet();
        caseManager = ICaseManager(_caseManager);
        caseManagerSet = true;
    }

    function setQuorum(uint256 bps) external {
        require(accessControl.hasRole(accessControl.ADMIN_ROLE(), msg.sender), "Not ADMIN_ROLE");
        require(bps <= 10000, "Invalid bps");
        quorumBps = bps;
        emit QuorumUpdated(bps);
    }

    function setRewardAndSlashAmount(uint256 rewardAmount, uint256 slashAmount) external {
        require(accessControl.hasRole(accessControl.ADMIN_ROLE(), msg.sender), "Not ADMIN_ROLE");
        voteRewardAmount = rewardAmount;
        voteSlashAmount = slashAmount;
        emit RewardSlashAmountUpdated(rewardAmount, slashAmount);
    }

    /// @notice Update the total staked weight used for quorum calculation.
    /// @dev    For MVP: admin updates this manually or via off-chain listener.
    ///         Production upgrade: integrate an on-chain total tracking in ValidatorRegistry.
    function setTotalStakedWeight(uint256 newTotal) external {
        require(accessControl.hasRole(accessControl.ADMIN_ROLE(), msg.sender), "Not ADMIN_ROLE");
        totalStakedWeight = newTotal;
        emit TotalStakedWeightUpdated(newTotal);
    }

    function _castVote(bytes32 targetHash, bool supportsValid, address voter) internal {
        if (!validatorRegistry.isActive(voter)) revert NotActiveValidator();
        if (votes[targetHash][voter].validator != address(0)) revert AlreadyVoted();

        Case memory c = caseManager.getCase(targetHash);
        if (c.status != CaseStatus.Voting) revert CaseNotVoting();

        // Snapshot the validator's current staked balance as their voting weight.
        // This weight is used for tally/quorum (Sybil resistance) but NOT for reward/slash size.
        uint256 weight = validatorRegistry.stakedBalanceOf(voter);

        // Initialize tally lazily on first vote
        if (tallies[targetHash].startTime == 0) {
            tallies[targetHash] = VoteTally({
                targetHash: targetHash, votesFor: 0, votesAgainst: 0, startTime: c.openedAt, resolved: false
            });
        }

        if (supportsValid) {
            tallies[targetHash].votesFor += weight;
        } else {
            tallies[targetHash].votesAgainst += weight;
        }

        votes[targetHash][voter] = ValidatorVote({validator: voter, supportsValid: supportsValid, weight: weight});
        voterList[targetHash].push(voter);

        // Lock validator's stake against unstake until this vote is resolved
        validatorRegistry.incrementActiveVoteCount(voter);

        emit VoteCast(targetHash, voter, supportsValid, weight);
    }

    /// @notice Called exclusively by CaseManager when a validator opens a new case.
    ///         Casts the opener's first vote in the same transaction as openCaseAndVote().
    function castVoteFrom(bytes32 targetHash, bool supportsValid, address voter) external {
        if (msg.sender != address(caseManager)) revert NotCaseManager();
        _castVote(targetHash, supportsValid, voter);
    }

    /// @notice Called directly by any active validator to add their vote on an open case.
    function castVote(bytes32 targetHash, bool supportsValid) external {
        _castVote(targetHash, supportsValid, msg.sender);
    }

    /// @notice Resolve a case after the voting period ends. Anyone can trigger this.
    /// @dev    nonReentrant guards against callback-based re-entry through treasury.reward()
    ///         or any future token with hooks. tally.resolved = true is also set early
    ///         as an additional CEI-compliant guard.
    function resolveVote(bytes32 targetHash) external nonReentrant {
        VoteTally storage tally = tallies[targetHash];
        Case memory c = caseManager.getCase(targetHash);

        if (c.status != CaseStatus.Voting) revert CaseNotVoting();
        if (block.timestamp < c.openedAt + caseManager.VOTING_PERIOD()) revert VotingPeriodNotEnded();
        if (tally.resolved) revert AlreadyResolved();

        uint256 voterCount = voterList[targetHash].length;
        if (voterCount > MAX_VOTERS_PER_RESOLVE) revert TooManyVoters();

        // --- Checks ---
        // Enforce quorum: total participating voting weight must exceed threshold.
        // Quorum is calculated as quorumBps/10000 of the total staked weight in the system.
        uint256 totalParticipatingWeight = tally.votesFor + tally.votesAgainst;
        if (totalStakedWeight > 0) {
            uint256 requiredWeight = (totalStakedWeight * quorumBps) / 10000;
            if (totalParticipatingWeight < requiredWeight) revert QuorumNotMet();
        }

        // Majority: more For than Against → Valid; tie → Invalid
        bool isValid = tally.votesFor > tally.votesAgainst;

        // --- Effects ---
        tally.resolved = true;

        // Finalize case status in CaseManager
        caseManager.finalizeCase(targetHash, isValid);

        // Update social risk score in RiskRegistry.
        // socialRisk semantics: 1=Low, 2=Medium, 3=High
        // If the case is VALID (community agrees it's risky), socialRisk = High (3).
        // If the case is INVALID (community says no problem), socialRisk = Low (1).
        riskRegistry.updateSocialScore(targetHash, isValid ? 3 : 1);

        emit CaseResolved(targetHash, isValid ? CaseStatus.Valid : CaseStatus.Invalid);

        // --- Interactions ---
        // Distribute flat rewards to majority voters; slash minority voters.
        // activeVoteCount is decremented here so validators can unstake after resolution.
        for (uint256 i = 0; i < voterCount; i++) {
            address voter = voterList[targetHash][i];
            ValidatorVote memory v = votes[targetHash][voter];

            if (v.supportsValid == isValid) {
                // Majority: allocate flat reward from Treasury pool
                treasury.reward(voter, voteRewardAmount);
            } else {
                // Minority: slash flat amount from ValidatorRegistry, transferred to Treasury
                validatorRegistry.slash(voter, voteSlashAmount);
            }

            // Unlock validator's stake so they can unstake if desired
            validatorRegistry.decrementActiveVoteCount(voter);
        }
    }
}
