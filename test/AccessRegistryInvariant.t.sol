// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessRegistry} from "../src/AccessRegistry.sol";

contract AccessRegistryHandler is Test {
    AccessRegistry public immutable registry;
    address public immutable outsider;

    address[] internal _candidates;
    address[] internal _users;
    address[] public tracked;
    mapping(address => address) public addedBy;
    mapping(address => bool) internal _seen;

    constructor(AccessRegistry registry_, address outsider_, address[] memory candidates_, address[] memory users_) {
        registry = registry_;
        outsider = outsider_;
        for (uint256 i; i < candidates_.length; i++) {
            _candidates.push(candidates_[i]);
        }
        for (uint256 i; i < users_.length; i++) {
            _users.push(users_[i]);
        }
    }

    function trackedLength() external view returns (uint256) {
        return tracked.length;
    }

    function addAdmin(uint256 callerSeed, uint256 accountSeed) external {
        address caller = _caller(callerSeed);
        address account = _candidates[accountSeed % _candidates.length];
        vm.prank(caller);
        try registry.addAdmin(account, "") {} catch {}
    }

    function removeAdmin(uint256 callerSeed, uint256 accountSeed) external {
        address caller = _caller(callerSeed);
        address account = _candidates[accountSeed % _candidates.length];
        vm.prank(caller);
        try registry.removeAdmin(account) {} catch {}
    }

    function addToWhitelist(uint256 callerSeed, uint256 userSeed) external {
        address caller = _caller(callerSeed);
        address user = _users[userSeed % _users.length];
        vm.prank(caller);
        try registry.addToWhitelist(user, "") {
            require(addedBy[user] == address(0), "user already tracked");
            _note(user, caller);
        } catch {}
    }

    function removeFromWhitelist(uint256 callerSeed, uint256 userSeed) external {
        address caller = _caller(callerSeed);
        address user = _users[userSeed % _users.length];
        vm.prank(caller);
        try registry.removeFromWhitelist(user) {
            require(addedBy[user] != address(0), "removed unknown user");
            addedBy[user] = address(0);
        } catch {}
    }

    function addToWhitelistBatch(uint256 callerSeed, uint256 userSeed) external {
        address caller = _caller(callerSeed);
        address first = _users[userSeed % _users.length];
        address second = _users[(userSeed + 1) % _users.length];
        if (first == second) return;
        address[] memory accounts = new address[](2);
        string[] memory notes = new string[](2);
        accounts[0] = first;
        accounts[1] = second;
        vm.prank(caller);
        try registry.addToWhitelistBatch(accounts, notes) {
            require(addedBy[first] == address(0) && addedBy[second] == address(0), "user already tracked");
            _note(first, caller);
            _note(second, caller);
        } catch {}
    }

    function removeFromWhitelistBatch(uint256 callerSeed, uint256 userSeed) external {
        address caller = _caller(callerSeed);
        address first = _users[userSeed % _users.length];
        address second = _users[(userSeed + 3) % _users.length];
        if (first == second) return;
        address[] memory accounts = new address[](2);
        accounts[0] = first;
        accounts[1] = second;
        vm.prank(caller);
        try registry.removeFromWhitelistBatch(accounts) {
            require(addedBy[first] != address(0) && addedBy[second] != address(0), "removed unknown user");
            addedBy[first] = address(0);
            addedBy[second] = address(0);
        } catch {}
    }

    function transferOwnership(uint256 callerSeed, uint256 nextSeed) external {
        address caller = _caller(callerSeed);
        address nextOwner = _nextOwner(nextSeed);
        vm.prank(caller);
        try registry.transferOwnership(nextOwner) {} catch {}
    }

    function acceptOwnership(uint256 callerSeed) external {
        address caller = _caller(callerSeed);
        _accept(caller);
    }

    function acceptPending() external {
        _accept(registry.pendingOwner());
    }

    function _accept(address caller) internal {
        if (caller == address(0)) return;
        address oldOwner = registry.owner();
        vm.prank(caller);
        try registry.acceptOwnership() {
            if (oldOwner == caller) return;
            uint256 length = tracked.length;
            for (uint256 i; i < length; i++) {
                address user = tracked[i];
                if (addedBy[user] == oldOwner) addedBy[user] = caller;
            }
        } catch {}
    }

    function _note(address user, address by) internal {
        addedBy[user] = by;
        if (_seen[user]) return;
        _seen[user] = true;
        tracked.push(user);
    }

    function _caller(uint256 seed) internal view returns (address) {
        uint256 bucket = seed % 10;
        if (bucket < 5) return registry.owner();
        if (bucket < 8) return _candidates[seed % _candidates.length];
        return outsider;
    }

    function _nextOwner(uint256 seed) internal view returns (address) {
        uint256 bucket = seed % 5;
        if (bucket == 0) return outsider;
        if (bucket == 1) return registry.owner();
        return _candidates[seed % _candidates.length];
    }
}

contract AccessRegistryInvariantTest is Test {
    AccessRegistry internal registry;
    AccessRegistryHandler internal handler;

    function setUp() public {
        address owner = makeAddr("owner");
        AccessRegistry implementation = new AccessRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(AccessRegistry.initialize, (owner))
        );
        registry = AccessRegistry(payable(address(proxy)));

        address[] memory candidates = new address[](6);
        address[] memory users = new address[](12);
        for (uint256 i; i < candidates.length; i++) {
            candidates[i] = makeAddr(string.concat("candidate", vm.toString(i)));
        }
        for (uint256 i; i < users.length; i++) {
            users[i] = makeAddr(string.concat("user", vm.toString(i)));
        }

        handler = new AccessRegistryHandler(registry, makeAddr("outsider"), candidates, users);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.addAdmin.selector;
        selectors[1] = handler.removeAdmin.selector;
        selectors[2] = handler.addToWhitelist.selector;
        selectors[3] = handler.removeFromWhitelist.selector;
        selectors[4] = handler.addToWhitelistBatch.selector;
        selectors[5] = handler.removeFromWhitelistBatch.selector;
        selectors[6] = handler.transferOwnership.selector;
        selectors[7] = handler.acceptOwnership.selector;
        selectors[8] = handler.acceptPending.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
        excludeContract(address(registry));
        excludeContract(address(implementation));
    }

    function invariant_versionAndAdminCap() public {
        assertEq(registry.layoutVersion(), 1);
        address owner = registry.owner();
        assertEq(uint8(registry.roleOf(owner)), uint8(AccessRegistry.Role.SuperAdmin));
        vm.prank(owner);
        assertLe(registry.adminCount(), registry.adminLimit());
    }

    function invariant_whitelistMatchesOperators() public {
        address owner = registry.owner();
        vm.prank(owner);
        uint256 listed = registry.whitelistCount();
        address[] memory admins = _admins();

        uint256 ghostListed;
        uint256 length = handler.trackedLength();
        for (uint256 i; i < length; i++) {
            address user = handler.tracked(i);
            address by = handler.addedBy(user);
            if (by == address(0)) {
                assertFalse(registry.isWhitelisted(user));
                continue;
            }
            ghostListed++;
            assertTrue(registry.isWhitelisted(user));
            assertFalse(_contains(_personal(owner), user) && by != owner);
            for (uint256 j; j < admins.length; j++) {
                bool inAdminList = _contains(_personal(admins[j]), user);
                if (inAdminList) assertEq(by, admins[j]);
                if (by == admins[j]) assertTrue(inAdminList);
            }
            if (by == owner) assertTrue(_contains(_personal(owner), user));
        }
        assertEq(listed, ghostListed);
        assertEq(_uniqueCount(_allWhitelist()), listed);
    }

    function _admins() internal returns (address[] memory admins) {
        vm.prank(registry.owner());
        admins = registry.getAdmins();
        for (uint256 i; i < admins.length; i++) {
            assertEq(uint8(registry.roleOf(admins[i])), uint8(AccessRegistry.Role.Admin));
            assertTrue(admins[i] != registry.owner());
            for (uint256 j = i + 1; j < admins.length; j++) {
                assertTrue(admins[i] != admins[j]);
            }
        }
    }

    function _personal(address operator) internal returns (address[] memory all) {
        vm.prank(operator);
        uint256 count = registry.myWhitelistCount();
        all = new address[](count);
        uint256 filled;
        for (uint256 offset; offset < count; offset += 50) {
            vm.prank(operator);
            address[] memory page = registry.getMyWhitelistPage(offset, 50);
            for (uint256 i; i < page.length; i++) {
                all[filled++] = page[i];
            }
        }
    }

    function _allWhitelist() internal returns (address[] memory all) {
        address owner = registry.owner();
        vm.prank(owner);
        uint256 count = registry.whitelistCount();
        all = new address[](count);
        uint256 filled;
        for (uint256 offset; offset < count; offset += 50) {
            vm.prank(owner);
            address[] memory page = registry.getWhitelistPage(offset, 50);
            for (uint256 i; i < page.length; i++) {
                all[filled++] = page[i];
            }
        }
    }

    function _contains(address[] memory list, address account) internal pure returns (bool) {
        for (uint256 i; i < list.length; i++) {
            if (list[i] == account) return true;
        }
        return false;
    }

    function _uniqueCount(address[] memory list) internal pure returns (uint256 count) {
        for (uint256 i; i < list.length; i++) {
            bool seen;
            for (uint256 j; j < i; j++) {
                if (list[j] == list[i]) seen = true;
            }
            if (!seen) count++;
        }
    }
}
