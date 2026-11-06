// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OtcTrade} from "../contracts/OtcTrade.sol";

/// @notice 仅部署代理（实现已单独 forge create）。
contract DeployOtcProxy is Script {
    function run() external returns (address proxy) {
        address implementation = vm.envAddress("OTC_IMPL");
        address registry = vm.envOr(
            "ACCESS_REGISTRY_PROXY", address(0x135Fb34eBAd72BB91932E22ff48Fa6963f0e5F9E)
        );
        uint256 key = vm.envUint("SEPOLIA_PRIVATE_KEY");
        address initialOwner = vm.addr(key);
        if (vm.envExists("INITIAL_OWNER")) {
            string memory rawOwner = vm.envString("INITIAL_OWNER");
            if (bytes(rawOwner).length != 0) initialOwner = vm.parseAddress(rawOwner);
        }

        vm.startBroadcast(key);
        proxy = address(
            new ERC1967Proxy(
                implementation, abi.encodeCall(OtcTrade.initialize, (initialOwner, registry))
            )
        );
        vm.stopBroadcast();
    }
}
