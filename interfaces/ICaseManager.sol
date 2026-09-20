// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

enum CaseStatus { None, Voting, Valid, Invalid, Escalated }

struct Case {
    bytes32 targetHash;
    string evidenceURI;
    uint256 openedAt;
    address openedBy;
    CaseStatus status;
}

interface ICaseManager {
    function openCaseAndVote(bytes32 targetHash, string calldata evidenceURI, bool supportsValid) external;
    function getCase(bytes32 targetHash) external view returns (Case memory);
    function finalizeCase(bytes32 targetHash, bool isValid) external;
    function VOTING_PERIOD() external view returns (uint256);
}
