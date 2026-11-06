// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {AccessRegistry} from "../contracts/AccessRegistry.sol";

/// @notice 升级已经部署的 Sepolia 代理。代理地址不变。
/// @dev Sepolia 部署逻辑合约约需 14M gas；若 forge script 估气过低导致 CREATE OOG，先单独 forge create / cast send --create，再 upgradeToAndCall。
contract UpgradeAccessRegistry is Script {
    /// @dev 产品和前端继续使用这个地址。
    address internal constant PROXY = 0x135Fb34eBAd72BB91932E22ff48Fa6963f0e5F9E;

    function run() external returns (address implementation) {
        uint256 key = vm.envUint("SEPOLIA_PRIVATE_KEY");

        vm.startBroadcast(key);
        implementation = address(new AccessRegistry());
        AccessRegistry(payable(PROXY)).upgradeToAndCall(implementation, "");
        vm.stopBroadcast();
    }
}
