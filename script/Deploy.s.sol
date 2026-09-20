// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {AccessControlManager} from "../src/AccessControlManager.sol";
import {Treasury} from "../src/Treasury.sol";
import {ValidatorRegistry} from "../src/ValidatorRegistry.sol";
import {RiskRegistry} from "../src/RiskRegistry.sol";
import {VotingModule} from "../src/VotingModule.sol";
import {CaseManager} from "../src/CaseManager.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey =
            vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)); // Anvil default account 0
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Mock USDC
        MockERC20 usdc = new MockERC20();

        // Mint some for deployer to fund treasury and stake
        usdc.mint(deployer, 1_000_000 * 10 ** 18);

        // 2. Deploy AccessControlManager
        AccessControlManager accessControl = new AccessControlManager(deployer);

        // 3. Deploy Treasury
        Treasury treasury = new Treasury(address(usdc), address(accessControl));

        // 4. Deploy ValidatorRegistry
        // e.g. min stake = 100 USDC (assuming 18 decimals for mock)
        uint256 minStake = 100 * 10 ** 18;
        ValidatorRegistry validatorRegistry =
            new ValidatorRegistry(address(usdc), address(accessControl), address(treasury), minStake);

        // 5. Deploy RiskRegistry
        RiskRegistry riskRegistry = new RiskRegistry(address(accessControl));

        // 6. Deploy VotingModule
        // Reward: 0.5 USDC, Slash: 1 USDC
        uint256 rewardAmount = 5 * 10 ** 17; // 0.5 * 10^18
        uint256 slashAmount = 1 * 10 ** 18;

        VotingModule votingModule = new VotingModule(
            address(accessControl),
            address(validatorRegistry),
            address(riskRegistry),
            address(treasury),
            rewardAmount,
            slashAmount
        );

        // 7. Deploy CaseManager
        CaseManager caseManager = new CaseManager(address(accessControl), address(validatorRegistry));
        caseManager.setVotingModule(address(votingModule));
        votingModule.setCaseManager(address(caseManager));

        // 8. Grant Roles
        // VotingModule needs SLASHER_ROLE to call:
        //   - ValidatorRegistry.slash() / incrementActiveVoteCount() / decrementActiveVoteCount()
        //   - Treasury.reward()
        accessControl.grantRole(accessControl.SLASHER_ROLE(), address(votingModule));

        // VotingModule needs VOTING_ROLE to call RiskRegistry.updateSocialScore()
        accessControl.grantRole(accessControl.VOTING_ROLE(), address(votingModule));

        // 9. Initialize totalStakedWeight for quorum calculation (0 = quorum disabled until set)
        // In production, admin should set this after validators stake.
        // votingModule.setTotalStakedWeight(0); // already 0 by default

        vm.stopBroadcast();

        console.log("Deployed USDC:", address(usdc));
        console.log("Deployed AccessControlManager:", address(accessControl));
        console.log("Deployed Treasury:", address(treasury));
        console.log("Deployed ValidatorRegistry:", address(validatorRegistry));
        console.log("Deployed RiskRegistry:", address(riskRegistry));
        console.log("Deployed VotingModule:", address(votingModule));
        console.log("Deployed CaseManager:", address(caseManager));
    }
}
