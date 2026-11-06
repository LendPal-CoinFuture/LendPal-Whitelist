// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice OTC 只读白名单合约上「在不在名单」的接口。
interface IAccessRegistry {
    function isWhitelisted(address account) external view returns (bool);
}
