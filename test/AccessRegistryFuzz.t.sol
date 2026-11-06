// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessRegistry} from "../contracts/AccessRegistry.sol";

contract AccessRegistryFuzzTest is Test {
    AccessRegistry internal registry;
    address internal owner = makeAddr("owner");
    address internal adminA = makeAddr("adminA");

    function setUp() public {
        AccessRegistry implementation = new AccessRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(AccessRegistry.initialize, (owner))
        );
        registry = AccessRegistry(payable(address(proxy)));
        vm.prank(owner);
        registry.addAdmin(adminA, "");
    }

    function testFuzz_outsiderCannotAddUser(address hacker, address user) public {
        vm.assume(hacker != address(0) && hacker != owner && hacker != adminA);
        vm.assume(user != address(0) && user != owner && user != adminA);

        vm.prank(hacker);
        vm.expectRevert(AccessRegistry.NotOperator.selector);
        registry.addToWhitelist(user, "");

        assertFalse(registry.isWhitelisted(user));
    }

    function testFuzz_outsiderCannotAddOrRemoveAdmin(address hacker, address account) public {
        vm.assume(hacker != address(0) && hacker != owner);

        vm.startPrank(hacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, hacker));
        registry.addAdmin(account, "");
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, hacker));
        registry.removeAdmin(adminA);
        vm.stopPrank();

        assertEq(uint8(registry.roleOf(adminA)), uint8(AccessRegistry.Role.Admin));
    }

    function testFuzz_duplicateUserAlwaysReverts(address user) public {
        vm.assume(user != address(0));

        vm.prank(owner);
        registry.addToWhitelist(user, "");
        vm.prank(adminA);
        vm.expectRevert(AccessRegistry.UserAlreadyWhitelisted.selector);
        registry.addToWhitelist(user, "");

        assertTrue(registry.isWhitelisted(user));
        vm.prank(adminA);
        assertEq(registry.myWhitelistCount(), 0);
    }

    function testFuzz_randomCallerCannotDeleteForeignUser(address caller) public {
        address user = makeAddr("listed-user");
        vm.prank(adminA);
        registry.addToWhitelist(user, "");
        vm.assume(caller != owner && caller != adminA);

        vm.prank(caller);
        vm.expectRevert(AccessRegistry.NotOperator.selector);
        registry.removeFromWhitelist(user);

        assertTrue(registry.isWhitelisted(user));
    }

    function testFuzz_removeAdminKeepsRandomUser(address user) public {
        vm.assume(user != address(0) && user != owner && user != adminA);

        vm.prank(adminA);
        registry.addToWhitelist(user, "");
        vm.prank(owner);
        registry.removeAdmin(adminA);

        assertTrue(registry.isWhitelisted(user));
        assertEq(uint8(registry.roleOf(adminA)), uint8(AccessRegistry.Role.None));
        vm.prank(adminA);
        vm.expectRevert(AccessRegistry.NotOperator.selector);
        registry.removeFromWhitelist(user);
    }

    function testFuzz_upgradeRejectsRandomCalldata(bytes calldata data) public {
        vm.assume(data.length > 0 && data.length <= 64);

        vm.prank(owner);
        vm.expectRevert(AccessRegistry.UpgradeCalldataDisabled.selector);
        registry.upgradeToAndCall(makeAddr("next-impl"), data);

        assertEq(registry.owner(), owner);
        assertEq(registry.layoutVersion(), 1);
    }
}
