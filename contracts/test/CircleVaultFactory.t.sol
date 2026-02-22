// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {CircleVaultFactory} from "../src/CircleFactory.sol";
import {CircleVault} from "../src/CircleVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVRFWrapper} from "./mocks/MockVRFWrapper.sol";

contract CircleIdLibTestHelper {
    function computeCircleId(
        address creator,
        string calldata name,
        uint256 startTimestamp,
        uint256 targetValue,
        uint256 totalInstallments,
        uint256 timePerRound,
        uint256 numRounds,
        uint256 numUsers,
        uint16 exitFeeBps,
        uint256 quotaCapEarly,
        uint256 quotaCapMiddle,
        uint256 quotaCapLate
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            creator, name, startTimestamp, targetValue, totalInstallments,
            timePerRound, numRounds, numUsers, exitFeeBps,
            quotaCapEarly, quotaCapMiddle, quotaCapLate
        ));
    }
}

contract CircleVaultFactoryTest is Test {
    CircleVaultFactory public factory;
    MockERC20 public paymentToken;
    MockVRFWrapper public vrfWrapper;
    CircleIdLibTestHelper public idHelper;

    function _circleId(CircleVault.CircleParams memory p) internal view returns (bytes32) {
        return idHelper.computeCircleId(
            address(this), p.name, p.startTimestamp, p.targetValue,
            p.totalInstallments, p.timePerRound, p.numRounds, p.numUsers,
            p.exitFeeBps, p.quotaCapEarly, p.quotaCapMiddle, p.quotaCapLate
        );
    }

    function setUp() public {
        factory = new CircleVaultFactory();
        paymentToken = new MockERC20("Test USDC", "USDC", 6);
        paymentToken.mint(address(this), 1_000_000e6);
        vrfWrapper = new MockVRFWrapper(address(0));
        idHelper = new CircleIdLibTestHelper();
    }

    function _validParams() internal view returns (CircleVault.CircleParams memory) {
        return CircleVault.CircleParams({
            name: "Test Circle",
            targetValue: 1000e6,
            totalInstallments: 10,
            startTimestamp: block.timestamp + 1 days,
            totalDurationDays: 90,
            timePerRound: 30 days,
            numRounds: 3,
            numUsers: 3,
            exitFeeBps: 100,
            paymentToken: address(paymentToken),
            shareToken: address(0),
            positionNft: address(0),
            quotaCapEarly: 1,
            quotaCapMiddle: 1,
            quotaCapLate: 1,
            drawConsumer: address(0),
            vrfWrapper: address(vrfWrapper)
        });
    }

    function test_CreateCircle_Success() public {
        CircleVault.CircleParams memory p = _validParams();
        bytes32 circleId = _circleId(p);

        address vaultAddr = factory.createCircle(p);

        assertTrue(vaultAddr != address(0), "Vault should be deployed");
        assertEq(factory.getCirclesCount(), 1, "Circle count should be 1");

        CircleVaultFactory.CircleInfo memory info = factory.getCircle(circleId);
        assertEq(info.vault, vaultAddr, "Vault address should match");
        assertTrue(info.shareToken != address(0), "Share token should be deployed");
        assertTrue(info.positionNft != address(0), "Position NFT should be deployed");
        assertTrue(info.drawConsumer != address(0), "Draw consumer should be deployed");
    }

    function test_CreateCircle_RevertWhen_InvalidTimePerRound() public {
        CircleVault.CircleParams memory p = _validParams();
        p.timePerRound = 0;

        vm.expectRevert(CircleVaultFactory.InvalidTimePerRound.selector);
        factory.createCircle(p);
    }

    function test_CreateCircle_RevertWhen_InvalidStartTime() public {
        CircleVault.CircleParams memory p = _validParams();
        p.startTimestamp = block.timestamp;

        vm.expectRevert(CircleVaultFactory.InvalidStartTime.selector);
        factory.createCircle(p);
    }

    function test_CreateCircle_RevertWhen_InvalidExitFee() public {
        CircleVault.CircleParams memory p = _validParams();
        p.exitFeeBps = 501;

        vm.expectRevert(CircleVaultFactory.InvalidExitFee.selector);
        factory.createCircle(p);
    }

    function test_CreateCircle_RevertWhen_InvalidTotalInstallments() public {
        CircleVault.CircleParams memory p = _validParams();
        p.totalInstallments = 0;

        vm.expectRevert(CircleVaultFactory.InvalidTotalInstallments.selector);
        factory.createCircle(p);
    }

    function test_CreateCircle_RevertWhen_InvalidRoundsUsers() public {
        CircleVault.CircleParams memory p = _validParams();
        p.numRounds = 3;
        p.numUsers = 5;

        vm.expectRevert(CircleVaultFactory.InvalidRoundsUsers.selector);
        factory.createCircle(p);
    }

    function test_CreateCircle_RevertWhen_InvalidQuotaCaps() public {
        CircleVault.CircleParams memory p = _validParams();
        p.quotaCapEarly = 1;
        p.quotaCapMiddle = 1;
        p.quotaCapLate = 0; // 1+1+0 != 3

        vm.expectRevert(CircleVaultFactory.InvalidQuotaCaps.selector);
        factory.createCircle(p);
    }

    function test_CreateCircle_RevertWhen_CircleAlreadyExists() public {
        CircleVault.CircleParams memory p = _validParams();
        factory.createCircle(p);

        vm.expectRevert(CircleVaultFactory.CircleAlreadyExists.selector);
        factory.createCircle(p);
    }

    function test_CreateCircle_OwnershipTransferred() public {
        CircleVault.CircleParams memory p = _validParams();
        address vaultAddr = factory.createCircle(p);

        CircleVault vault = CircleVault(payable(vaultAddr));
        assertEq(vault.owner(), address(this), "Vault owner should be creator");
    }

    function test_CreateCircle_MultipleCircles() public {
        CircleVault.CircleParams memory p = _validParams();
        address vault1 = factory.createCircle(p);

        p.name = "Test Circle 2";
        p.startTimestamp = block.timestamp + 2 days;
        address vault2 = factory.createCircle(p);

        assertTrue(vault1 != vault2, "Vaults should be different");
        assertEq(factory.getCirclesCount(), 2, "Should have 2 circles");
    }
}
