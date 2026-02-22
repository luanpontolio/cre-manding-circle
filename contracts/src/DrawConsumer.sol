// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title DrawConsumer
 * @notice Consumes Chainlink VRF v2.5 randomness via Direct Funding to shuffle participant order.
 * @dev Uses VRFV2PlusWrapperConsumerBase - fund this contract with LINK (or native tokens) before requesting draws.
 * @dev See: https://docs.chain.link/vrf/v2-5/overview/direct-funding
 */
contract DrawConsumer is VRFV2PlusWrapperConsumerBase, Ownable {
    uint32 private constant VRF_CALLBACK_GAS_LIMIT = 100_000;
    uint16 private constant VRF_REQUEST_CONFIRMATIONS = 3;
    uint32 private constant VRF_NUM_WORDS = 1;

    /// @notice Pending participants for each request until VRF is fulfilled.
    mapping(uint256 => address[]) private _pendingParticipants;

    /// @notice Fulfilled draw order per request id.
    mapping(uint256 => address[]) private _drawOrder;

    /// @notice Whether the request has been fulfilled.
    mapping(uint256 => bool) private _drawCompleted;

    event DrawRequested(uint256 indexed requestId, uint256 indexed quotaId, uint256 participantCount);
    event DrawFulfilled(uint256 indexed requestId);

    error OnlyVault();
    error EmptyParticipants();
    error NotFulfilled();
    error InvalidWrapper();

    /// @notice Uses VRF v2.5 Wrapper (Base Sepolia: 0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed)
    constructor(address vrfWrapper_)
    VRFV2PlusWrapperConsumerBase(vrfWrapper_)
    Ownable(msg.sender)
    {}

    function requestDraw(uint256 quotaId, address[] calldata participants) external returns (uint256 requestId) {
        if (msg.sender != owner()) revert OnlyVault();
        if (participants.length == 0) revert EmptyParticipants();

        bytes memory extraArgs =
            VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}));
        (requestId,) = requestRandomness(VRF_CALLBACK_GAS_LIMIT, VRF_REQUEST_CONFIRMATIONS, VRF_NUM_WORDS, extraArgs);

        _pendingParticipants[requestId] = participants;
        emit DrawRequested(requestId, quotaId, participants.length);
        return requestId;
    }

    /// @dev Called by VRF Wrapper via rawFulfillRandomWords when randomness is fulfilled.
    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        address[] memory list = _pendingParticipants[_requestId];
        if (list.length == 0) revert NotFulfilled();
        if (_randomWords.length == 0) revert InvalidWrapper();

        uint256 n = list.length;
        for (uint256 i = n; i > 1; i--) {
            uint256 j = uint256(keccak256(abi.encode(_randomWords[0], i))) % i;
            (list[i - 1], list[j]) = (list[j], list[i - 1]);
        }
        for (uint256 k = 0; k < n; k++) {
            _drawOrder[_requestId].push(list[k]);
        }
        _drawCompleted[_requestId] = true;
        delete _pendingParticipants[_requestId];

        emit DrawFulfilled(_requestId);
    }

    function drawCompleted(uint256 requestId) external view returns (bool) {
        return _drawCompleted[requestId];
    }

    function getDrawOrder(uint256 requestId) external view returns (address[] memory) {
        return _drawOrder[requestId];
    }

    /// @notice Withdraw LINK tokens to owner. Use when contract has excess LINK after draws.
    function withdrawLink() external onlyOwner {
        LinkTokenInterface link = getLinkToken();
        require(link.transfer(owner(), link.balanceOf(address(this))), "Link transfer failed");
    }

    /// @notice Withdraw native tokens to owner.
    function withdrawNative(uint256 amount) external onlyOwner {
        (bool success,) = payable(owner()).call{value: amount}("");
        require(success, "Native transfer failed");
    }

    receive() external payable {}
}
