// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDrawConsumer {
    function requestDraw(uint256 quotaId, address[] calldata participants) external returns (uint256);
    function drawCompleted(uint256 requestId) external view returns (bool);
    function getDrawOrder(uint256 requestId) external view returns (address[] memory);
}