// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControlManager} from "./AccessControlManager.sol";
import {IRiskRegistry, RiskScore} from "../interfaces/IRiskRegistry.sol";

contract RiskRegistry is IRiskRegistry {
    AccessControlManager public accessControl;
    
    mapping(bytes32 => RiskScore) public scores;

    event ScoreUpdated(bytes32 indexed targetHash, uint8 technicalRisk, uint8 socialRisk, uint8 shariahFlag);
    event ShariahFlagUpdated(bytes32 indexed targetHash, uint8 flag, bytes32 fatwaRef);

    constructor(address _accessControl) {
        accessControl = AccessControlManager(_accessControl);
    }

    modifier onlyOracle() {
        require(accessControl.hasRole(accessControl.ORACLE_ROLE(), msg.sender), "Not ORACLE_ROLE");
        _;
    }

    modifier onlyVotingModule() {
        require(accessControl.hasRole(accessControl.VOTING_ROLE(), msg.sender), "Not VOTING_ROLE");
        _;
    }

    function updateTechnicalScore(bytes32 targetHash, uint8 risk) external onlyOracle {
        scores[targetHash].technicalRisk = risk;
        scores[targetHash].lastUpdated = block.timestamp;
        emit ScoreUpdated(targetHash, risk, scores[targetHash].socialRisk, scores[targetHash].shariahFlag);
    }

    function updateSocialScore(bytes32 targetHash, uint8 risk) external onlyVotingModule {
        scores[targetHash].socialRisk = risk;
        scores[targetHash].lastUpdated = block.timestamp;
        emit ScoreUpdated(targetHash, scores[targetHash].technicalRisk, risk, scores[targetHash].shariahFlag);
    }

    function updateShariahFlag(bytes32 targetHash, uint8 flag, bytes32 fatwaRef) external onlyOracle {
        scores[targetHash].shariahFlag = flag;
        scores[targetHash].lastUpdated = block.timestamp;
        emit ScoreUpdated(targetHash, scores[targetHash].technicalRisk, scores[targetHash].socialRisk, flag);
        emit ShariahFlagUpdated(targetHash, flag, fatwaRef);
    }

    function getScore(bytes32 targetHash) external view returns (RiskScore memory) {
        return scores[targetHash];
    }
}
