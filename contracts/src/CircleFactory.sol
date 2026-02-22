// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import {CircleIdLib} from "./library/CircleIdLib.sol";
import {CircleVault} from "./CircleVault.sol";
import {ERC20Claim} from "./ERC20Claim.sol";
import {PositionNFT} from "./PositionNFT.sol";
import {DrawConsumer} from "./DrawConsumer.sol";

contract CircleVaultFactory is Ownable {
    uint256 public circleCount;
    mapping(bytes32 => CircleInfo) public circleInfoById;
    mapping(bytes32 => address) public circleById;

    struct CircleInfo {
        bytes32 circleId;
        address vault;
        address shareToken;
        address positionNft;
        address drawConsumer;
    }

    event CircleCreated(
        address indexed vault,
        address indexed creator,
        bytes32 indexed circleId,
        string name
    );

    error CircleAlreadyExists();
    error InvalidTimePerRound();
    error InvalidStartTime();
    error InvalidExitFee();
    error InvalidTotalInstallments();
    error InvalidRoundsUsers();
    error InvalidQuotaCaps();

    constructor() Ownable(msg.sender) {}

    function createCircle(CircleVault.CircleParams calldata p) external returns (address vaultAddr) {
        _validateCreateParams(p);

        bytes32 circleId = _computeCircleId(p);
        _ensureCircleDoesNotExist(circleId);

        ERC20Claim shareToken = new ERC20Claim("Mandinga Claim", "MCLM", address(this));
        PositionNFT positionNft = new PositionNFT("Mandinga Position", "MPOS", address(this));
        DrawConsumer drawConsumer = new DrawConsumer(p.vrfWrapper);

        CircleVault.CircleParams memory params = CircleVault.CircleParams({
            name: p.name,
            targetValue: p.targetValue,
            totalInstallments: p.totalInstallments,
            startTimestamp: p.startTimestamp,
            totalDurationDays: p.totalDurationDays,
            timePerRound: p.timePerRound,
            numRounds: p.numRounds,
            numUsers: p.numUsers,
            exitFeeBps: p.exitFeeBps,
            paymentToken: p.paymentToken,
            shareToken: address(shareToken),
            positionNft: address(positionNft),
            quotaCapEarly: p.quotaCapEarly,
            quotaCapMiddle: p.quotaCapMiddle,
            quotaCapLate: p.quotaCapLate,
            drawConsumer: address(drawConsumer),
            vrfWrapper: p.vrfWrapper
        });

        CircleVault vault = new CircleVault(params, msg.sender);

        _recordCircle(circleId, address(vault), address(shareToken), address(positionNft), address(drawConsumer));
        _transferOwnership(vault, shareToken, positionNft, drawConsumer);

        emit CircleCreated(address(vault), msg.sender, circleId, p.name);
        return address(vault);
    }

    function getCircle(bytes32 circleId) external view returns (CircleInfo memory) {
        return circleInfoById[circleId];
    }

    function getCirclesCount() external view returns (uint256) {
        return circleCount;
    }

    function _validateCreateParams(CircleVault.CircleParams calldata p) internal view {
        if (p.timePerRound == 0) revert InvalidTimePerRound();
        if (p.startTimestamp <= block.timestamp) revert InvalidStartTime();
        if (p.exitFeeBps > 500) revert InvalidExitFee();
        if (p.totalInstallments == 0) revert InvalidTotalInstallments();
        if (p.numUsers != p.numRounds) revert InvalidRoundsUsers();
        if (p.quotaCapEarly + p.quotaCapMiddle + p.quotaCapLate != p.numUsers) {
            revert InvalidQuotaCaps();
        }
    }

    function _computeCircleId(CircleVault.CircleParams calldata p) internal view returns (bytes32) {
        return CircleIdLib.compute(
            msg.sender,
            p.name,
            p.startTimestamp,
            p.targetValue,
            p.totalInstallments,
            p.timePerRound,
            p.numRounds,
            p.numUsers,
            p.exitFeeBps,
            p.quotaCapEarly,
            p.quotaCapMiddle,
            p.quotaCapLate
        );
    }

    function _ensureCircleDoesNotExist(bytes32 circleId) internal view {
        if (circleById[circleId] != address(0)) revert CircleAlreadyExists();
    }

    function _transferOwnership(CircleVault vault, ERC20Claim shareToken, PositionNFT positionNft, DrawConsumer drawConsumer) internal {
        shareToken.transferOwnership(address(vault));
        positionNft.transferOwnership(address(vault));
        drawConsumer.transferOwnership(address(vault));
    }

    function _recordCircle(
        bytes32 circleId,
        address vault,
        address shareToken,
        address positionNft,
        address drawConsumer
    ) internal {
        circleById[circleId] = vault;
        circleCount++;
        circleInfoById[circleId] = CircleInfo({
            circleId: circleId,
            vault: vault,
            shareToken: shareToken,
            positionNft: positionNft,
            drawConsumer: drawConsumer
        });
    }
}
