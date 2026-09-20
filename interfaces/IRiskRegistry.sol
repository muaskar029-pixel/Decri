// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct RiskScore {
    uint8 technicalRisk;
    uint8 socialRisk;
    uint8 shariahFlag;
    uint256 lastUpdated;
    uint256 caseCount;
}

interface IRiskRegistry {
    function updateTechnicalScore(bytes32 targetHash, uint8 risk) external;
    function updateSocialScore(bytes32 targetHash, uint8 risk) external;
    function updateShariahFlag(bytes32 targetHash, uint8 flag, bytes32 fatwaRef) external;
    function getScore(bytes32 targetHash) external view returns (RiskScore memory);
}
