// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDrawConsumer} from "../../src/interfaces/IDrawConsumer.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Mock DrawConsumer for testing - immediately returns a deterministic order without VRF.
contract MockDrawConsumer is IDrawConsumer, Ownable {
    mapping(uint256 => address[]) private _drawOrder;
    mapping(uint256 => bool) private _drawCompleted;

    constructor() Ownable(msg.sender) {}

    function requestDraw(uint256 quotaId, address[] calldata participants) external override returns (uint256 requestId) {
        requestId = quotaId; // Use quotaId as requestId for deterministic testing
        _drawOrder[requestId] = participants;
        _drawCompleted[requestId] = true;
        return requestId;
    }

    function drawCompleted(uint256 requestId) external view override returns (bool) {
        return _drawCompleted[requestId];
    }

    function getDrawOrder(uint256 requestId) external view override returns (address[] memory) {
        return _drawOrder[requestId];
    }
}
