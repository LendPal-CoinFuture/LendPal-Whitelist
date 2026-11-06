// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {OtcTrade} from "../contracts/OtcTrade.sol";

/// @notice 升级已部署的 OtcTrade 代理。代理地址不变。
contract UpgradeOtcTrade is Script {
    address internal constant DEFAULT_PROXY = 0x1c0865085D32ad95C730AF0879F0642a48b732c5;

    function run() external returns (address implementation) {
        address proxy = DEFAULT_PROXY;
        if (vm.envExists("OTC_TRADE_PROXY")) {
            string memory raw = vm.envString("OTC_TRADE_PROXY");
            if (bytes(raw).length != 0) proxy = vm.parseAddress(raw);
        }
        uint256 key = vm.envUint("SEPOLIA_PRIVATE_KEY");

        vm.startBroadcast(key);
        implementation = address(new OtcTrade());
        OtcTrade(proxy).upgradeToAndCall(implementation, "");
        vm.stopBroadcast();
    }
}
