// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IValidatorRegistry {
    function stake(uint256 amount) external;
    function unstake(uint256 amount) external;
    function slash(address validator, uint256 amount) external;
    function isActive(address validator) external view returns (bool);
    function incrementActiveVoteCount(address validator) external;
    function decrementActiveVoteCount(address validator) external;
    function stakedBalanceOf(address validator) external view returns (uint256);
}
