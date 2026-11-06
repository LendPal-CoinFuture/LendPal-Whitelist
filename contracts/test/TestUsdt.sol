// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice 测试用 USDT，不用于生产。6 位小数。只有部署者可以铸币。
contract TestUsdt is ERC20, Ownable {
    constructor(address initialOwner) ERC20("Test USDT", "USDT") Ownable(initialOwner) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice 给测试地址铸币。正式环境应换成真实 USDT，并不再使用这个合约。
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
