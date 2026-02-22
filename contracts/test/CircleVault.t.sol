// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {CircleVault} from "../src/CircleVault.sol";
import {CircleVaultFactory} from "../src/CircleFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVRFWrapper} from "./mocks/MockVRFWrapper.sol";
import {PositionNFT} from "../src/PositionNFT.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CircleVaultTest is Test {
    CircleVaultFactory public factory;
    MockERC20 public paymentToken;
    MockVRFWrapper public vrfWrapper;
    CircleVault public vault;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xC4A01);

    uint256 constant TARGET = 1000e6;
    uint256 constant INSTALLMENTS = 10;
    uint256 constant INSTALLMENT_AMOUNT = 100e6;

    function setUp() public {
        factory = new CircleVaultFactory();
        paymentToken = new MockERC20("Test USDC", "USDC", 6);
        paymentToken.mint(alice, 100_000e6);
        paymentToken.mint(bob, 100_000e6);
        paymentToken.mint(carol, 100_000e6);
        paymentToken.mint(address(this), 100_000e6);
        vrfWrapper = new MockVRFWrapper(address(0));

        CircleVault.CircleParams memory p = CircleVault.CircleParams({
            name: "Test Circle",
            targetValue: TARGET,
            totalInstallments: INSTALLMENTS,
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

        address vaultAddr = factory.createCircle(p);
        vault = CircleVault(payable(vaultAddr));
    }

    function test_Deposit_Success() public {
        vm.startPrank(alice);
        paymentToken.approve(address(vault), INSTALLMENT_AMOUNT);
        vault.deposit(0); // quota early

        assertTrue(vault.isEnrolled(alice));
        assertEq(vault.activeParticipantCount(), 1);
        assertEq(vault.participants(0), alice);
        assertEq(paymentToken.balanceOf(address(vault)), INSTALLMENT_AMOUNT);
        vm.stopPrank();
    }

    function test_Deposit_RevertWhen_AlreadyEnrolled() public {
        vm.startPrank(alice);
        paymentToken.approve(address(vault), INSTALLMENT_AMOUNT);
        vault.deposit(0);
        vm.expectRevert();
        vault.deposit(1);
        vm.stopPrank();
    }

    function test_Deposit_RevertWhen_QuotaFull() public {
        vm.startPrank(alice);
        paymentToken.approve(address(vault), INSTALLMENT_AMOUNT);
        vault.deposit(0); // fills early quota (cap=1)
        vm.stopPrank();

        vm.startPrank(bob);
        paymentToken.approve(address(vault), INSTALLMENT_AMOUNT);
        vm.expectRevert(); // QuotaFull
        vault.deposit(0);
        vm.stopPrank();
    }

    function test_Deposit_RevertWhen_AfterDeadline() public {
        vm.warp(block.timestamp + 40 days); // Past early window close
        vm.startPrank(alice);
        paymentToken.approve(address(vault), INSTALLMENT_AMOUNT);
        vm.expectRevert(); // JoinAfterDeadline
        vault.deposit(0);
        vm.stopPrank();
    }

    function test_PayInstallment_Success() public {
        vm.startPrank(alice);
        paymentToken.approve(address(vault), TARGET);
        vault.deposit(0);
        vault.payInstallment();
        vm.stopPrank();

        (uint256 tokenId,,,, uint256 totalPaid,) = _getPositionData(alice);
        assertEq(totalPaid, 2 * INSTALLMENT_AMOUNT);
    }

    function test_ExitEarly_Success() public {
        vm.startPrank(alice);
        paymentToken.approve(address(vault), INSTALLMENT_AMOUNT);
        vault.deposit(0);
        uint256 claimBalance = IERC20(vault.shareToken()).balanceOf(alice);
        IERC20(vault.shareToken()).approve(address(vault), claimBalance);
        vault.exitEarly(claimBalance);
        vm.stopPrank();

        uint256 expectedNet = claimBalance - (claimBalance * 100 / 10_000);
        assertEq(paymentToken.balanceOf(alice), 100_000e6 - INSTALLMENT_AMOUNT + expectedNet);
        assertFalse(vault.isEnrolled(alice));
    }

    function test_GetCloseWindowTimestamp() public view {
        uint256 early = vault.getCloseWindowTimestamp(0);
        uint256 middle = vault.getCloseWindowTimestamp(1);
        uint256 late = vault.getCloseWindowTimestamp(2);

        assertGt(early, block.timestamp);
        assertGt(middle, early);
        assertGt(late, middle);
    }

    function test_GetCurrentPhase() public {
        vm.warp(block.timestamp + 1);
        assertEq(uint256(vault.getCurrentPhase(block.timestamp)), 0); // EARLY before start

        vm.warp(vault.startTimestamp() + 1);
        assertEq(uint256(vault.getCurrentPhase(block.timestamp)), 0); // EARLY

        vm.warp(vault.startTimestamp() + 31 days);
        assertEq(uint256(vault.getCurrentPhase(block.timestamp)), 1); // MIDDLE

        vm.warp(vault.startTimestamp() + 61 days);
        assertEq(uint256(vault.getCurrentPhase(block.timestamp)), 2); // LATE
    }

    function test_IsEnrolled() public {
        assertFalse(vault.isEnrolled(alice));
        vm.startPrank(alice);
        paymentToken.approve(address(vault), INSTALLMENT_AMOUNT);
        vault.deposit(0);
        vm.stopPrank();
        assertTrue(vault.isEnrolled(alice));
    }

    function test_CanCloseWindow_BeforeDeadline() public {
        vm.startPrank(alice);
        paymentToken.approve(address(vault), INSTALLMENT_AMOUNT);
        vault.deposit(0);
        vm.stopPrank();

        vm.warp(vault.startTimestamp() + 1 days);
        assertFalse(vault.canCloseWindow(0)); // Deadline not passed, pot may not be sufficient
    }

    function test_CanCloseWindow_AfterDeadline() public {
        vm.startPrank(alice);
        paymentToken.approve(address(vault), INSTALLMENT_AMOUNT);
        vault.deposit(0);
        vm.stopPrank();

        vm.warp(vault.getCloseWindowTimestamp(0) + 1);
        assertTrue(vault.canCloseWindow(0));
    }

    function _getPositionData(address participant) internal view returns (
        uint256 tokenId,
        uint256 quotaId,
        uint256 targetValue,
        uint256 totalInstallments,
        uint256 totalPaid,
        uint256 status
    ) {
        tokenId = vault.participantToTokenId(participant);
        PositionNFT positionNft = PositionNFT(vault.positionNft());
        PositionNFT.PositionData memory pos = positionNft.getPosition(tokenId);
        return (tokenId, pos.quotaId, pos.targetValue, pos.totalInstallments, pos.totalPaid, uint256(pos.status));
    }
}
