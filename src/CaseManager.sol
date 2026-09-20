// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControlManager} from "./AccessControlManager.sol";
import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";
import {IVotingModule} from "../interfaces/IVotingModule.sol";
import {ICaseManager, Case, CaseStatus} from "../interfaces/ICaseManager.sol";

/// @title CaseManager
/// @notice Entry point for validators to open risk verification cases on-chain.
///         A case is only recorded on-chain when an active validator decides to act on it.
///         Off-chain reports from visitors exist purely in the backend database.
contract CaseManager is ICaseManager {
    AccessControlManager public immutable accessControl;
    IValidatorRegistry public immutable validatorRegistry;
    IVotingModule public votingModule;

    /// @dev Lock to prevent re-setting votingModule after it has been initialized once.
    bool public votingModuleSet;

    mapping(bytes32 => Case) public cases;
    uint256 public constant VOTING_PERIOD = 3 days;
    bool public paused;

    event CaseOpened(bytes32 indexed targetHash, address indexed openedBy, string evidenceURI);
    event CaseFinalized(bytes32 indexed targetHash, CaseStatus status);
    event Paused(address account);
    event Unpaused(address account);

    error ZeroAddress();
    error AlreadySet();
    error CaseAlreadyExists();
    error NotActiveValidator();
    error NotVotingModule();
    error ContractPaused();

    constructor(address _accessControl, address _validatorRegistry) {
        if (_accessControl == address(0) || _validatorRegistry == address(0)) revert ZeroAddress();
        accessControl = AccessControlManager(_accessControl);
        validatorRegistry = IValidatorRegistry(_validatorRegistry);
    }

    /// @notice Set the VotingModule address. Can only be called ONCE after deployment.
    /// @dev    Immutable after first set — prevents admin from swapping logic contract
    ///         to a malicious one mid-operation.
    function setVotingModule(address _votingModule) external {
        require(accessControl.hasRole(accessControl.ADMIN_ROLE(), msg.sender), "Not ADMIN_ROLE");
        if (_votingModule == address(0)) revert ZeroAddress();
        if (votingModuleSet) revert AlreadySet();
        votingModule = IVotingModule(_votingModule);
        votingModuleSet = true;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    function pause() external {
        require(accessControl.hasRole(accessControl.PAUSER_ROLE(), msg.sender), "Not PAUSER_ROLE");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external {
        require(accessControl.hasRole(accessControl.PAUSER_ROLE(), msg.sender), "Not PAUSER_ROLE");
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Opens a new case on-chain and simultaneously casts the opener's first vote.
    /// @dev    Race condition guard: require status == None prevents two validators from
    ///         opening the same case simultaneously — second tx will revert cleanly.
    function openCaseAndVote(bytes32 targetHash, string calldata evidenceURI, bool supportsValid)
        external
        whenNotPaused
    {
        if (!validatorRegistry.isActive(msg.sender)) revert NotActiveValidator();
        if (cases[targetHash].status != CaseStatus.None) revert CaseAlreadyExists();

        cases[targetHash] = Case({
            targetHash: targetHash,
            evidenceURI: evidenceURI,
            openedAt: block.timestamp,
            openedBy: msg.sender,
            status: CaseStatus.Voting
        });

        // Emit BEFORE delegating to VotingModule so event ordering is: CaseOpened → VoteCast
        emit CaseOpened(targetHash, msg.sender, evidenceURI);

        // Delegate first vote to VotingModule on behalf of opener
        votingModule.castVoteFrom(targetHash, supportsValid, msg.sender);
    }

    function getCase(bytes32 targetHash) external view returns (Case memory) {
        return cases[targetHash];
    }

    /// @notice Called exclusively by VotingModule after voting period ends to record final verdict.
    function finalizeCase(bytes32 targetHash, bool isValid) external {
        if (msg.sender != address(votingModule)) revert NotVotingModule();
        cases[targetHash].status = isValid ? CaseStatus.Valid : CaseStatus.Invalid;
        emit CaseFinalized(targetHash, cases[targetHash].status);
    }
}
