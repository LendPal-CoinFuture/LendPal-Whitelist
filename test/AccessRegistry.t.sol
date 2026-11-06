// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {AccessRegistry} from "../src/AccessRegistry.sol";

contract AccessRegistryV2 is AccessRegistry {
    function versionMarker() external pure returns (uint256) {
        return 2;
    }
}

contract EthSender {
    function send(address to) external payable {
        (bool ok, bytes memory data) = to.call{value: msg.value}("");
        if (!ok) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
    }
}

contract AccessRegistryTest is Test {
    AccessRegistry internal registry;

    address internal owner = makeAddr("owner");
    address internal nextOwner = makeAddr("nextOwner");
    address internal adminA = makeAddr("adminA");
    address internal adminB = makeAddr("adminB");
    address internal userS = makeAddr("userS");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");

    function setUp() public {
        AccessRegistry implementation = new AccessRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(AccessRegistry.initialize, (owner))
        );
        registry = AccessRegistry(payable(address(proxy)));
    }

    function test_initializeSetsOwnerAndVersion() public view {
        assertEq(registry.owner(), owner);
        assertEq(registry.layoutVersion(), 1);
        assertEq(uint8(registry.roleOf(owner)), uint8(AccessRegistry.Role.SuperAdmin));
    }

    function test_implementationCannotBeInitialized() public {
        AccessRegistry implementation = new AccessRegistry();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner);
    }

    function test_proxyCannotBeInitializedTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(owner);
    }

    function test_adminCannotAddOrRemoveAdmin() public {
        _addAdmin(adminA);
        _addAdmin(adminB);

        vm.startPrank(adminA);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, adminA));
        registry.removeAdmin(adminB);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, adminA));
        registry.addAdmin(adminB, "");
        vm.stopPrank();

        assertEq(uint8(registry.roleOf(adminB)), uint8(AccessRegistry.Role.Admin));
    }

    function test_isWhitelistedIncludesOwnerAndAdmin() public {
        assertTrue(registry.isWhitelisted(owner));
        assertFalse(registry.isWhitelisted(adminA));
        _addAdmin(adminA);
        assertTrue(registry.isWhitelisted(adminA));
        assertFalse(registry.isWhitelisted(userA));
        assertFalse(registry.isWhitelisted(address(0)));
    }

    function test_removeAdminKeepsAddedUsers() public {
        _addAdmin(adminA);
        _addUser(adminA, userA);

        vm.prank(owner);
        registry.removeAdmin(adminA);

        assertEq(uint8(registry.roleOf(adminA)), uint8(AccessRegistry.Role.None));
        assertTrue(registry.isWhitelisted(userA));
        assertFalse(registry.isWhitelisted(adminA));

        vm.prank(adminA);
        vm.expectRevert(AccessRegistry.NotOperator.selector);
        registry.removeFromWhitelist(userA);

        vm.prank(owner);
        address[] memory all = registry.getWhitelistPage(0, 50);
        assertEq(all.length, 1);
        assertEq(all[0], userA);
    }

    function test_adminCannotTouchAnotherAdminsUsers() public {
        _addAdmin(adminA);
        _addAdmin(adminB);
        _addUser(adminA, userA);
        _addUser(adminB, userB);

        vm.prank(adminA);
        vm.expectRevert(AccessRegistry.NotEntryOwner.selector);
        registry.removeFromWhitelist(userB);

        vm.prank(adminA);
        address[] memory mine = registry.getMyWhitelistPage(0, 50);
        assertEq(mine.length, 1);
        assertEq(mine[0], userA);

        vm.prank(adminA);
        address[] memory all = registry.getWhitelistPage(0, 50);
        assertEq(all.length, 2);
    }

    function test_duplicateUserIsRejected() public {
        _addAdmin(adminA);
        _addAdmin(adminB);
        _addUser(adminA, userA);

        assertTrue(registry.isWhitelisted(userA));

        vm.prank(adminB);
        vm.expectRevert(AccessRegistry.UserAlreadyWhitelisted.selector);
        registry.addToWhitelist(userA, "");

        vm.prank(adminB);
        assertEq(registry.myWhitelistCount(), 0);
    }

    function test_handoverMovesOnlySuperAdminUsers() public {
        _addAdmin(adminA);
        _addUser(owner, userS);
        _addUser(adminA, userA);

        vm.prank(owner);
        registry.transferOwnership(nextOwner);
        vm.prank(nextOwner);
        registry.acceptOwnership();

        assertEq(registry.owner(), nextOwner);
        assertTrue(registry.isWhitelisted(userS));
        assertTrue(registry.isWhitelisted(userA));

        vm.prank(nextOwner);
        address[] memory moved = registry.getMyWhitelistPage(0, 50);
        assertEq(moved.length, 1);
        assertEq(moved[0], userS);

        vm.prank(adminA);
        address[] memory kept = registry.getMyWhitelistPage(0, 50);
        assertEq(kept.length, 1);
        assertEq(kept[0], userA);

        vm.prank(owner);
        address[] memory oldOwnerPage = registry.getMyWhitelistPage(0, 50);
        assertEq(oldOwnerPage.length, 0);
    }

    function test_upgradeKeepsWhitelistAndVersion() public {
        _addUser(owner, userS);
        AccessRegistryV2 nextImplementation = new AccessRegistryV2();

        vm.prank(owner);
        registry.upgradeToAndCall(address(nextImplementation), "");

        AccessRegistryV2 upgraded = AccessRegistryV2(payable(address(registry)));
        assertEq(upgraded.versionMarker(), 2);
        assertEq(upgraded.layoutVersion(), 1);
        assertTrue(upgraded.isWhitelisted(userS));
        assertEq(upgraded.owner(), owner);
    }

    function test_upgradeRejectsCalldataValueAndAdmin() public {
        AccessRegistryV2 nextImplementation = new AccessRegistryV2();

        vm.prank(owner);
        vm.expectRevert(AccessRegistry.UpgradeCalldataDisabled.selector);
        registry.upgradeToAndCall(address(nextImplementation), hex"01");

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert(AccessRegistry.EthRejected.selector);
        registry.upgradeToAndCall{value: 1 ether}(address(nextImplementation), "");

        _addAdmin(adminA);
        vm.prank(adminA);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, adminA));
        registry.upgradeToAndCall(address(nextImplementation), "");
    }

    function test_outsiderCannotUsePrivilegedEntries() public {
        _addAdmin(adminA);
        _addUser(adminA, userA);
        address hacker = makeAddr("hacker");
        AccessRegistryV2 nextImplementation = new AccessRegistryV2();

        vm.startPrank(hacker);
        _expectOwnerOnly(hacker);
        registry.addAdmin(hacker, "");
        _expectOwnerOnly(hacker);
        registry.removeAdmin(adminA);
        _expectOwnerOnly(hacker);
        registry.transferOwnership(hacker);
        _expectOwnerOnly(hacker);
        registry.upgradeToAndCall(address(nextImplementation), "");
        address[] memory admins = registry.getAdmins();
        assertEq(admins.length, 1);
        assertEq(admins[0], adminA);
        assertEq(registry.adminCount(), 1);
        assertEq(registry.whitelistCount(), 1);
        address[] memory page = registry.getWhitelistPage(0, 50);
        assertEq(page.length, 1);
        assertEq(page[0], userA);
        address[] memory hackerPage = registry.getMyWhitelistPage(0, 50);
        assertEq(hackerPage.length, 0);
        _expectOwnerOnly(hacker);
        registry.setAdminLimit(1);
        vm.expectRevert(AccessRegistry.NotOperator.selector);
        registry.addToWhitelist(hacker, "");
        vm.expectRevert(AccessRegistry.NotOperator.selector);
        registry.removeFromWhitelist(userA);
        address[] memory hackerOwn = registry.getMyWhitelistPage(0, 50);
        assertEq(hackerOwn.length, 0);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, hacker));
        registry.acceptOwnership();
        vm.expectRevert(AccessRegistry.RenounceDisabled.selector);
        registry.renounceOwnership();
        vm.stopPrank();

        assertEq(registry.owner(), owner);
        assertEq(uint8(registry.roleOf(adminA)), uint8(AccessRegistry.Role.Admin));
        assertEq(uint8(registry.roleOf(hacker)), uint8(AccessRegistry.Role.None));
        assertTrue(registry.isWhitelisted(userA));
        assertFalse(registry.isWhitelisted(hacker));
    }

    function test_adminCannotEscalate() public {
        _addAdmin(adminA);
        _addAdmin(adminB);
        _addUser(adminB, userB);
        AccessRegistryV2 nextImplementation = new AccessRegistryV2();

        vm.startPrank(adminA);
        _expectOwnerOnly(adminA);
        registry.addAdmin(makeAddr("extra"), "");
        _expectOwnerOnly(adminA);
        registry.removeAdmin(adminB);
        _expectOwnerOnly(adminA);
        registry.removeAdmin(adminA);
        _expectOwnerOnly(adminA);
        registry.transferOwnership(adminA);
        _expectOwnerOnly(adminA);
        registry.upgradeToAndCall(address(nextImplementation), "");
        address[] memory visibleAdmins = registry.getAdmins();
        assertEq(visibleAdmins.length, 2);
        address[] memory visibleUsers = registry.getWhitelistPage(0, 50);
        assertEq(visibleUsers.length, 1);
        assertEq(visibleUsers[0], userB);
        _expectOwnerOnly(adminA);
        registry.setAdminLimit(1);
        vm.expectRevert(AccessRegistry.NotEntryOwner.selector);
        registry.removeFromWhitelist(userB);
        vm.expectRevert(AccessRegistry.UserAlreadyWhitelisted.selector);
        registry.addToWhitelist(userB, "");
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, adminA));
        registry.acceptOwnership();
        vm.stopPrank();

        assertEq(registry.owner(), owner);
        assertEq(uint8(registry.roleOf(adminA)), uint8(AccessRegistry.Role.Admin));
        assertEq(uint8(registry.roleOf(adminB)), uint8(AccessRegistry.Role.Admin));
        assertTrue(registry.isWhitelisted(userB));
        vm.prank(adminB);
        assertEq(registry.myWhitelistCount(), 1);
    }

    function test_removedAdminCannotWriteAgain() public {
        _addAdmin(adminA);
        _addUser(adminA, userA);
        vm.prank(owner);
        registry.removeAdmin(adminA);

        vm.startPrank(adminA);
        vm.expectRevert(AccessRegistry.NotOperator.selector);
        registry.addToWhitelist(userB, "");
        vm.expectRevert(AccessRegistry.NotOperator.selector);
        registry.removeFromWhitelist(userA);
        _expectOwnerOnly(adminA);
        registry.addAdmin(adminA, "");
        vm.stopPrank();

        assertTrue(registry.isWhitelisted(userA));
        assertFalse(registry.isWhitelisted(userB));
    }

    function test_ownershipCannotBeTakenOrGivenToAdmin() public {
        _addAdmin(adminA);

        vm.prank(owner);
        vm.expectRevert(AccessRegistry.OwnerCannotBeAdmin.selector);
        registry.transferOwnership(adminA);

        vm.prank(adminA);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, adminA));
        registry.acceptOwnership();
        assertEq(registry.owner(), owner);
    }

    function test_directUpgradeOnImplementationReverts() public {
        AccessRegistry implementation = new AccessRegistry();
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        implementation.upgradeToAndCall(address(implementation), "");
    }

    function test_renounceAndDirectEthFail() public {
        vm.prank(owner);
        vm.expectRevert(AccessRegistry.RenounceDisabled.selector);
        registry.renounceOwnership();

        EthSender sender = new EthSender();
        vm.deal(address(sender), 1 ether);
        vm.expectRevert(AccessRegistry.EthRejected.selector);
        sender.send{value: 1 ether}(address(registry));
    }

    function test_defaultAdminLimitIs200() public view {
        assertEq(registry.adminLimit(), 200);
        assertEq(registry.DEFAULT_ADMIN_LIMIT(), 200);
    }

    function test_ownerCanChangeAdminLimit() public {
        address adminC = makeAddr("adminC");

        vm.startPrank(owner);
        registry.setAdminLimit(2);
        registry.addAdmin(adminA, "");
        registry.addAdmin(adminB, "");
        vm.expectRevert(AccessRegistry.AdminCapacityReached.selector);
        registry.addAdmin(adminC, "");
        registry.setAdminLimit(3);
        registry.addAdmin(adminC, "");
        vm.stopPrank();

        assertEq(registry.adminLimit(), 3);
        assertEq(uint8(registry.roleOf(adminC)), uint8(AccessRegistry.Role.Admin));
    }

    function test_cannotLowerLimitBelowExistingAdmins() public {
        _addAdmin(adminA);
        _addAdmin(adminB);

        vm.prank(owner);
        vm.expectRevert(AccessRegistry.AdminLimitTooSmall.selector);
        registry.setAdminLimit(1);

        assertEq(registry.adminLimit(), 200);
        vm.prank(owner);
        registry.setAdminLimit(2);
        assertEq(registry.adminLimit(), 2);
    }

    function test_unsetStoredLimitUsesDefaultAfterUpgrade() public {
        bytes32 base = 0xd305b90518e6fe535c399942b2c8ed71039b6599030b4fa85d6ed3cf0b93cb00;
        assertEq(uint256(vm.load(address(registry), bytes32(uint256(base) + 8))), 200);
        assertEq(uint256(vm.load(address(registry), bytes32(uint256(base) + 9))), 1);

        vm.store(address(registry), bytes32(uint256(base) + 8), bytes32(0));
        vm.store(address(registry), bytes32(uint256(base) + 9), bytes32(0));
        assertEq(registry.adminLimit(), 200);
        assertEq(registry.layoutVersion(), 1);

        vm.prank(owner);
        registry.setAdminLimit(0);
        assertEq(registry.adminLimit(), 0);

        vm.prank(owner);
        vm.expectRevert(AccessRegistry.AdminCapacityReached.selector);
        registry.addAdmin(adminA, "");
    }

    function test_adminAndOwnerCanBatchAdd() public {
        _addAdmin(adminA);
        address[] memory accounts = new address[](2);
        string[] memory notes = new string[](2);
        accounts[0] = userA;
        accounts[1] = userB;
        notes[0] = "a";
        notes[1] = "b";

        vm.expectEmit(true, true, false, true);
        emit AccessRegistry.WhitelistAdded(userA, adminA, "a");
        vm.expectEmit(true, true, false, true);
        emit AccessRegistry.WhitelistAdded(userB, adminA, "b");
        vm.prank(adminA);
        registry.addToWhitelistBatch(accounts, notes);

        assertTrue(registry.isWhitelisted(userA));
        assertTrue(registry.isWhitelisted(userB));
        assertEq(registry.whitelistNoteOf(userA), "a");
        assertEq(registry.whitelistNoteOf(userB), "b");
        assertEq(registry.whitelistCount(), 2);
        vm.prank(adminA);
        assertEq(registry.myWhitelistCount(), 2);

        address userC = makeAddr("userC");
        address[] memory more = new address[](1);
        string[] memory moreNotes = new string[](1);
        more[0] = userC;
        vm.prank(owner);
        registry.addToWhitelistBatch(more, moreNotes);
        assertTrue(registry.isWhitelisted(userC));
        vm.prank(owner);
        assertEq(registry.myWhitelistCount(), 1);
    }

    function test_batchAddRevertsAndRollsBack() public {
        _addAdmin(adminA);
        _addUser(adminA, userA);

        address[] memory accounts = new address[](2);
        string[] memory notes = new string[](2);
        accounts[0] = userB;
        accounts[1] = userA;

        vm.prank(adminB);
        vm.expectRevert(AccessRegistry.NotOperator.selector);
        registry.addToWhitelistBatch(accounts, notes);

        vm.prank(adminA);
        vm.expectRevert(AccessRegistry.UserAlreadyWhitelisted.selector);
        registry.addToWhitelistBatch(accounts, notes);
        assertFalse(registry.isWhitelisted(userB));
        assertEq(registry.whitelistCount(), 1);

        accounts[1] = userB;
        vm.prank(adminA);
        vm.expectRevert(AccessRegistry.UserAlreadyWhitelisted.selector);
        registry.addToWhitelistBatch(accounts, notes);
        assertFalse(registry.isWhitelisted(userB));

        vm.prank(adminA);
        vm.expectRevert(AccessRegistry.EmptyBatch.selector);
        registry.addToWhitelistBatch(new address[](0), new string[](0));

        vm.prank(adminA);
        vm.expectRevert(AccessRegistry.BatchLengthMismatch.selector);
        registry.addToWhitelistBatch(accounts, new string[](1));

        accounts[1] = address(0);
        vm.prank(adminA);
        vm.expectRevert(AccessRegistry.ZeroAddress.selector);
        registry.addToWhitelistBatch(accounts, notes);
        assertFalse(registry.isWhitelisted(userB));

        accounts[0] = userB;
        accounts[1] = makeAddr("userC");
        notes[1] = new string(65);
        vm.prank(adminA);
        vm.expectRevert(AccessRegistry.NoteTooLong.selector);
        registry.addToWhitelistBatch(accounts, notes);
        assertEq(registry.whitelistCount(), 1);

        address[] memory tooMany = new address[](51);
        string[] memory tooManyNotes = new string[](51);
        for (uint256 i; i < tooMany.length; i++) {
            tooMany[i] = address(uint160(i + 1));
        }
        vm.prank(owner);
        vm.expectRevert(AccessRegistry.BatchTooLarge.selector);
        registry.addToWhitelistBatch(tooMany, tooManyNotes);
    }

    function test_batchRemoveKeepsOperatorRules() public {
        _addAdmin(adminA);
        _addAdmin(adminB);
        _addUser(adminA, userA);
        _addUser(adminB, userB);
        _addUser(owner, userS);

        address[] memory own = new address[](1);
        own[0] = userA;
        vm.prank(adminA);
        registry.removeFromWhitelistBatch(own);
        assertFalse(registry.isWhitelisted(userA));
        assertEq(registry.whitelistCount(), 2);

        address[] memory mixed = new address[](2);
        mixed[0] = userS;
        mixed[1] = userB;
        vm.prank(adminB);
        vm.expectRevert(AccessRegistry.NotEntryOwner.selector);
        registry.removeFromWhitelistBatch(mixed);
        assertTrue(registry.isWhitelisted(userS));
        assertTrue(registry.isWhitelisted(userB));

        vm.prank(owner);
        registry.removeFromWhitelistBatch(mixed);
        assertFalse(registry.isWhitelisted(userS));
        assertFalse(registry.isWhitelisted(userB));
        assertEq(registry.whitelistCount(), 0);

        address[] memory twice = new address[](2);
        twice[0] = userA;
        twice[1] = userA;
        _addUser(adminA, userA);
        vm.prank(adminA);
        vm.expectRevert(AccessRegistry.NotListed.selector);
        registry.removeFromWhitelistBatch(twice);
        assertTrue(registry.isWhitelisted(userA));

        vm.prank(owner);
        vm.expectRevert(AccessRegistry.EmptyBatch.selector);
        registry.removeFromWhitelistBatch(new address[](0));

        address[] memory tooMany = new address[](51);
        vm.prank(owner);
        vm.expectRevert(AccessRegistry.BatchTooLarge.selector);
        registry.removeFromWhitelistBatch(tooMany);

        vm.prank(makeAddr("outsider"));
        vm.expectRevert(AccessRegistry.NotOperator.selector);
        registry.removeFromWhitelistBatch(own);
    }

    function test_batchAcceptsFifty() public {
        address[] memory accounts = new address[](50);
        string[] memory notes = new string[](50);
        for (uint256 i; i < accounts.length; i++) {
            accounts[i] = address(uint160(1000 + i));
        }

        vm.prank(owner);
        registry.addToWhitelistBatch(accounts, notes);
        assertEq(registry.whitelistCount(), 50);
        assertTrue(registry.isWhitelisted(accounts[0]));
        assertTrue(registry.isWhitelisted(accounts[49]));

        vm.prank(owner);
        registry.removeFromWhitelistBatch(accounts);
        assertEq(registry.whitelistCount(), 0);
        assertFalse(registry.isWhitelisted(accounts[0]));
        assertFalse(registry.isWhitelisted(accounts[49]));
    }

    function _expectOwnerOnly(address caller) private {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, caller));
    }

    function _addAdmin(address admin) private {
        vm.prank(owner);
        registry.addAdmin(admin, "");
    }

    function _addUser(address operator, address user) private {
        vm.prank(operator);
        registry.addToWhitelist(user, "");
    }
}
