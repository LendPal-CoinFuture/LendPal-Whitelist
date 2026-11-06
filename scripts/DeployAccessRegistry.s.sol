// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessRegistry} from "../contracts/AccessRegistry.sol";

contract DeployAccessRegistry is Script {
    function run() external returns (address proxy) {
        string memory network = vm.envOr("DEPLOY_NETWORK", string("sepolia"));
        uint256 key = _privateKey(network);
        address deployer = vm.addr(key);
        address initialOwner = deployer;
        if (vm.envExists("INITIAL_OWNER")) {
            string memory rawOwner = vm.envString("INITIAL_OWNER");
            if (bytes(rawOwner).length != 0) initialOwner = vm.parseAddress(rawOwner);
        }

        vm.startBroadcast(key);
        AccessRegistry implementation = new AccessRegistry();
        proxy = address(
            new ERC1967Proxy(address(implementation), abi.encodeCall(AccessRegistry.initialize, (initialOwner)))
        );
        vm.stopBroadcast();
    }

    function _privateKey(string memory network) internal view returns (uint256) {
        if (keccak256(bytes(network)) == keccak256("mainnet")) {
            return vm.envUint("MAINNET_PRIVATE_KEY");
        }
        return vm.envUint("SEPOLIA_PRIVATE_KEY");
    }
}
