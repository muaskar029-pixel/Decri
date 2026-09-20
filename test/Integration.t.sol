// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {AccessControlManager} from "../src/AccessControlManager.sol";
import {Treasury} from "../src/Treasury.sol";
import {ValidatorRegistry} from "../src/ValidatorRegistry.sol";
import {RiskRegistry} from "../src/RiskRegistry.sol";
import {VotingModule} from "../src/VotingModule.sol";
import {CaseManager} from "../src/CaseManager.sol";
import {CaseStatus, Case} from "../interfaces/ICaseManager.sol";

contract IntegrationTest is Test {
    MockERC20 usdc;
    AccessControlManager accessControl;
    Treasury treasury;
    ValidatorRegistry validatorRegistry;
    RiskRegistry riskRegistry;
    VotingModule votingModule;
    CaseManager caseManager;

    address admin = address(1);
    address alice = address(2);
    address bob = address(3);
    address charlie = address(4); // third validator
    address oracle = address(5);

    uint256 minStake = 100 * 10 ** 18;
    uint256 rewardAmount = 5 * 10 ** 17; // 0.5 USDC
    uint256 slashAmount = 1 * 10 ** 18; // 1 USDC

    function setUp() public {
        vm.startPrank(admin);

        usdc = new MockERC20();
        accessControl = new AccessControlManager(admin);
        treasury = new Treasury(address(usdc), address(accessControl));

        validatorRegistry = new ValidatorRegistry(address(usdc), address(accessControl), address(treasury), minStake);

        riskRegistry = new RiskRegistry(address(accessControl));

        votingModule = new VotingModule(
            address(accessControl),
            address(validatorRegistry),
            address(riskRegistry),
            address(treasury),
            rewardAmount,
            slashAmount
        );

        caseManager = new CaseManager(address(accessControl), address(validatorRegistry));

        // One-time wiring — will revert if called again (AlreadySet)
        caseManager.setVotingModule(address(votingModule));
        votingModule.setCaseManager(address(caseManager));

        // Grant roles
        accessControl.grantRole(accessControl.SLASHER_ROLE(), address(votingModule));
        accessControl.grantRole(accessControl.VOTING_ROLE(), address(votingModule));
        accessControl.grantRole(accessControl.ORACLE_ROLE(), oracle);

        // Fund treasury with 1000 USDC
        usdc.mint(admin, 1000 * 10 ** 18);
        usdc.approve(address(treasury), 1000 * 10 ** 18);
        treasury.fundPool(1000 * 10 ** 18);

        vm.stopPrank();

        // Mint tokens for validators
        usdc.mint(alice, 500 * 10 ** 18);
        usdc.mint(bob, 500 * 10 ** 18);
        usdc.mint(charlie, 500 * 10 ** 18);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // FULL HAPPY PATH FLOW
    // ─────────────────────────────────────────────────────────────────────────

    function testFullFlow_InvalidResult() public {
        // Alice stakes 100, Bob stakes 200 → Bob wins majority
        vm.startPrank(alice);
        usdc.approve(address(validatorRegistry), minStake);
        validatorRegistry.stake(minStake);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(validatorRegistry), minStake * 2);
        validatorRegistry.stake(minStake * 2);
        vm.stopPrank();

        // Set totalStakedWeight so quorum can be calculated (admin updates manually in MVP)
        // Total staked = 100 + 200 = 300. quorumBps=500 (5%). Minimum = 15 weight.
        // Both alice (100) + bob (200) will vote → 300 total → quorum met easily.
        vm.prank(admin);
        votingModule.setTotalStakedWeight(300 * 10 ** 18);

        bytes32 targetHash = keccak256("https://suspicious.site");
        string memory evidenceURI = "ipfs://Qm...";

        // Oracle sets technical score
        vm.prank(oracle);
        riskRegistry.updateTechnicalScore(targetHash, 3); // High risk

        // Alice opens case and votes: VALID (she thinks it's risky)
        vm.prank(alice);
        caseManager.openCaseAndVote(targetHash, evidenceURI, true);

        // Bob votes INVALID (he disagrees)
        vm.prank(bob);
        votingModule.castVote(targetHash, false);

        // ── Anti-evasion: Alice cannot unstake while her vote is pending ──
        vm.startPrank(alice);
        vm.expectRevert();
        validatorRegistry.unstake(minStake);
        vm.stopPrank();

        // ── Resolve after 3 days ──
        vm.warp(block.timestamp + 3 days + 1);
        votingModule.resolveVote(targetHash);

        // Bob (weight 200) > Alice (weight 100) → INVALID
        Case memory c = caseManager.getCase(targetHash);
        assertEq(uint256(c.status), uint256(CaseStatus.Invalid), "Status should be Invalid");

        // Alice was wrong → slashed 1 USDC from stake
        assertEq(
            validatorRegistry.stakedBalanceOf(alice),
            minStake - slashAmount,
            "Alice stake should be reduced by slashAmount"
        );

        // Bob was right → reward allocated
        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        treasury.claim();
        assertEq(usdc.balanceOf(bob), bobBalanceBefore + rewardAmount, "Bob should receive rewardAmount");

        // Alice's activeVoteCount should be back to 0 — she can now unstake
        // (though her balance is reduced from slash)
        vm.prank(alice);
        validatorRegistry.unstake(minStake - slashAmount);
        assertEq(validatorRegistry.stakedBalanceOf(alice), 0, "Alice staked balance should be 0");
    }

    function testFullFlow_ValidResult() public {
        // Alice stakes 200, Bob stakes 100 → Alice wins majority
        vm.startPrank(alice);
        usdc.approve(address(validatorRegistry), minStake * 2);
        validatorRegistry.stake(minStake * 2);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(validatorRegistry), minStake);
        validatorRegistry.stake(minStake);
        vm.stopPrank();

        vm.prank(admin);
        votingModule.setTotalStakedWeight(300 * 10 ** 18);

        bytes32 targetHash = keccak256("https://another-suspicious.site");

        // Alice opens case voting VALID, Bob votes INVALID
        vm.prank(alice);
        caseManager.openCaseAndVote(targetHash, "ipfs://evidence", true);
        vm.prank(bob);
        votingModule.castVote(targetHash, false);

        vm.warp(block.timestamp + 3 days + 1);
        votingModule.resolveVote(targetHash);

        // Alice (200) > Bob (100) → VALID
        Case memory c = caseManager.getCase(targetHash);
        assertEq(uint256(c.status), uint256(CaseStatus.Valid), "Status should be Valid");

        // Bob was wrong → slashed
        assertEq(validatorRegistry.stakedBalanceOf(bob), minStake - slashAmount);

        // Alice was right → reward
        vm.prank(alice);
        treasury.claim();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // REVERT / SECURITY PATHS
    // ─────────────────────────────────────────────────────────────────────────

    function testCannotDoubleVote() public {
        vm.startPrank(alice);
        usdc.approve(address(validatorRegistry), minStake);
        validatorRegistry.stake(minStake);
        vm.stopPrank();

        vm.prank(admin);
        votingModule.setTotalStakedWeight(minStake);

        bytes32 targetHash = keccak256("double-vote-test");
        vm.prank(alice);
        caseManager.openCaseAndVote(targetHash, "ipfs://evidence", true);

        // Alice tries to vote again → should revert
        vm.prank(alice);
        vm.expectRevert();
        votingModule.castVote(targetHash, false);
    }

    function testCannotOpenDuplicateCase() public {
        vm.startPrank(alice);
        usdc.approve(address(validatorRegistry), minStake);
        validatorRegistry.stake(minStake);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(validatorRegistry), minStake);
        validatorRegistry.stake(minStake);
        vm.stopPrank();

        vm.prank(admin);
        votingModule.setTotalStakedWeight(minStake * 2);

        bytes32 targetHash = keccak256("dup-case-test");
        vm.prank(alice);
        caseManager.openCaseAndVote(targetHash, "ipfs://evidence", true);

        // Bob tries to open the same case → should revert (race condition guard)
        vm.prank(bob);
        vm.expectRevert();
        caseManager.openCaseAndVote(targetHash, "ipfs://evidence", false);
    }

    function testCannotResolveBeforePeriodEnds() public {
        vm.startPrank(alice);
        usdc.approve(address(validatorRegistry), minStake);
        validatorRegistry.stake(minStake);
        vm.stopPrank();

        vm.prank(admin);
        votingModule.setTotalStakedWeight(minStake);

        bytes32 targetHash = keccak256("early-resolve-test");
        vm.prank(alice);
        caseManager.openCaseAndVote(targetHash, "ipfs://evidence", true);

        // Try to resolve immediately → should revert
        vm.expectRevert();
        votingModule.resolveVote(targetHash);
    }

    function testCannotResolveWhenQuorumNotMet() public {
        vm.startPrank(alice);
        usdc.approve(address(validatorRegistry), minStake);
        validatorRegistry.stake(minStake);
        vm.stopPrank();

        // Set total staked weight to 10000 USDC but only 100 USDC voted → 1% < 5% quorum
        vm.prank(admin);
        votingModule.setTotalStakedWeight(10000 * 10 ** 18);

        bytes32 targetHash = keccak256("quorum-fail-test");
        vm.prank(alice);
        caseManager.openCaseAndVote(targetHash, "ipfs://evidence", true);

        vm.warp(block.timestamp + 3 days + 1);

        // Should revert with QuorumNotMet
        vm.expectRevert();
        votingModule.resolveVote(targetHash);
    }

    function testCannotDoubleResolve() public {
        vm.startPrank(alice);
        usdc.approve(address(validatorRegistry), minStake);
        validatorRegistry.stake(minStake);
        vm.stopPrank();

        vm.prank(admin);
        votingModule.setTotalStakedWeight(minStake);

        bytes32 targetHash = keccak256("double-resolve-test");
        vm.prank(alice);
        caseManager.openCaseAndVote(targetHash, "ipfs://evidence", true);

        vm.warp(block.timestamp + 3 days + 1);
        votingModule.resolveVote(targetHash);

        // Second resolve → revert
        vm.expectRevert();
        votingModule.resolveVote(targetHash);
    }

    function testSetVotingModuleCanOnlyBeCalledOnce() public {
        // Admin tries to set votingModule again → AlreadySet revert
        vm.prank(admin);
        vm.expectRevert();
        caseManager.setVotingModule(address(0x1234));
    }

    function testSetCaseManagerCanOnlyBeCalledOnce() public {
        vm.prank(admin);
        vm.expectRevert();
        votingModule.setCaseManager(address(0x1234));
    }

    function testNonValidatorCannotOpenCase() public {
        bytes32 targetHash = keccak256("no-stake-test");
        // charlie never staked
        vm.prank(charlie);
        vm.expectRevert();
        caseManager.openCaseAndVote(targetHash, "ipfs://evidence", true);
    }

    function testNonValidatorCannotVote() public {
        vm.startPrank(alice);
        usdc.approve(address(validatorRegistry), minStake);
        validatorRegistry.stake(minStake);
        vm.stopPrank();

        vm.prank(admin);
        votingModule.setTotalStakedWeight(minStake);

        bytes32 targetHash = keccak256("no-stake-vote-test");
        vm.prank(alice);
        caseManager.openCaseAndVote(targetHash, "ipfs://evidence", true);

        // charlie never staked → cannot vote
        vm.prank(charlie);
        vm.expectRevert();
        votingModule.castVote(targetHash, false);
    }

    function testSlashedTokensGoToTreasury() public {
        vm.startPrank(alice);
        usdc.approve(address(validatorRegistry), minStake * 2); // Bob will have more weight
        validatorRegistry.stake(minStake);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(validatorRegistry), minStake * 2);
        validatorRegistry.stake(minStake * 2);
        vm.stopPrank();

        vm.prank(admin);
        votingModule.setTotalStakedWeight(300 * 10 ** 18);

        uint256 treasuryBalanceBefore = usdc.balanceOf(address(treasury));

        bytes32 targetHash = keccak256("slash-to-treasury-test");
        vm.prank(alice);
        caseManager.openCaseAndVote(targetHash, "ipfs://evidence", true); // Alice: valid
        vm.prank(bob);
        votingModule.castVote(targetHash, false); // Bob: invalid (majority)

        vm.warp(block.timestamp + 3 days + 1);
        votingModule.resolveVote(targetHash);

        // Treasury should have gained slashAmount from Alice
        // and decreased by Bob's pending reward (not yet claimed)
        uint256 treasuryBalanceAfter = usdc.balanceOf(address(treasury));
        // Net: +slashAmount from Alice's slash, -0 (Bob hasn't claimed yet)
        assertEq(
            treasuryBalanceAfter,
            treasuryBalanceBefore + slashAmount,
            "Treasury balance should increase by slashed amount"
        );
    }
}
