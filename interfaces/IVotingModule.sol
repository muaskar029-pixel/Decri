// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVotingModule {
    function castVote(bytes32 targetHash, bool supportsValid) external;
    function castVoteFrom(bytes32 targetHash, bool supportsValid, address voter) external;
    function resolveVote(bytes32 targetHash) external;
}
