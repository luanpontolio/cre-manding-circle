// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @notice Mock VRF Wrapper for testing. Implements minimal interface required by VRFV2PlusWrapperConsumerBase constructor.
 */
contract MockVRFWrapper {
    address public linkToken;

    constructor(address _linkToken) {
        linkToken = _linkToken;
    }

    function link() external view returns (address) {
        return linkToken;
    }
}
