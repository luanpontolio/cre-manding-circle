// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CircleErrors} from "./library/CircleErrors.sol";
import {PositionNFT} from "./PositionNFT.sol";
import {ERC20Claim} from "./ERC20Claim.sol";
import {IDrawConsumer} from "./interfaces/IDrawConsumer.sol";

contract CircleVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant SECONDS_PER_DAY = 86400;

    enum WindowPhase {
        EARLY,   // 0
        MIDDLE,  // 1
        LATE     // 2
    }

    struct CircleParams {
        string name;
        uint256 targetValue;
        uint256 totalInstallments;
        uint256 startTimestamp;
        uint256 totalDurationDays;
        uint256 timePerRound;
        uint256 numRounds;
        uint256 numUsers;
        uint16 exitFeeBps;
        address paymentToken;
        address shareToken;
        address positionNft;
        uint256 quotaCapEarly;
        uint256 quotaCapMiddle;
        uint256 quotaCapLate;
        address drawConsumer;
        address vrfWrapper;
    }

    enum CircleStatus {
        ACTIVE,
        FROZEN,
        SETTLED,
        CLOSED
    }

    address public immutable paymentToken;
    address public immutable shareToken;
    address public immutable positionNft;
    uint256 public immutable targetValue;
    uint256 public immutable totalInstallments;
    uint256 public immutable installmentAmount;
    uint256 public immutable numUsers;
    uint16 public immutable exitFeeBps;

    string public circleName;
    address public creator;
    uint256 public immutable startTimestamp;
    uint256 public immutable totalDurationDays;
    uint256 public timePerRound;
    uint256 public numberOfRounds;
    CircleStatus public status;

    mapping(address => uint256) public participantToTokenId;  // 0 = not enrolled
    address[] public participants;
    uint256 public activeParticipantCount;

    /// Quota capacities and filled counts: 0 = early, 1 = middle, 2 = late
    uint256 public immutable quotaCapEarly;
    uint256 public immutable quotaCapMiddle;
    uint256 public immutable quotaCapLate;
    uint256 public quotaFilledEarly;
    uint256 public quotaFilledMiddle;
    uint256 public quotaFilledLate;

    uint256 public snapshotTimestamp;
    uint256 public snapshotBalance;
    uint256 public snapshotClaimsSupply;

    /// Close window (deadline) per quota: when this timestamp is reached, that window can be snapshotted and drawn.
    /// Offsets: totalDurationDays / 3 per phase. Early = start + 1/3, Middle = start + 2/3, Late = start + total.
    uint256 public immutable closeWindowEarly;
    uint256 public immutable closeWindowMiddle;
    uint256 public immutable closeWindowLate;

    /// @notice Dedicated VRF draw consumer for this vault (one consumer per vault).
    address public immutable drawConsumer;

    uint256 private constant MAX_QUOTA_ID = 2;

    /// Per-window per-round snapshot: (quotaId, roundIndex) -> participants and balances.
    mapping(uint256 => mapping(uint256 => address[])) public windowParticipants;
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) public windowSnapshotBalance;
    mapping(uint256 => mapping(uint256 => bool)) public windowSnapshotted;
    mapping(uint256 => mapping(uint256 => uint256)) public windowSnapshotTimestamp;
    /// Total pot per round (sum of snapshot balances). Single contemplado receives full pot.
    mapping(uint256 => mapping(uint256 => uint256)) public windowTotalPot;

    /// Draw consumer request id per (quotaId, roundIndex).
    mapping(uint256 => mapping(uint256 => uint256)) public quotaIdRoundToRequestId;

    /// True after redeem for that round (quotaId, roundIndex).
    mapping(uint256 => mapping(uint256 => bool)) public windowRoundSettled;

    /// True if address has redeemed in that window (excluded from future round snapshots).
    mapping(uint256 => mapping(address => bool)) public hasRedeemedInWindow;

    event ParticipantEnrolled(
        address indexed participant,
        uint256 indexed tokenId,
        uint256 depositAmount
    );
    event InstallmentPaid(
        address indexed participant,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 totalPaid
    );
    event EarlyExit(
        address indexed participant,
        uint256 indexed tokenId,
        uint256 claimAmount,
        uint256 feeAmount,
        uint256 netAmount
    );
    event WindowSnapshotted(uint256 indexed quotaId, uint256 indexed roundIndex, uint256 timestamp, uint256 participantCount);
    event Redeemed(
        address indexed participant,
        uint256 indexed tokenId,
        uint256 indexed quotaId,
        uint256 amount,
        bytes32 proof
    );

    constructor(CircleParams memory p, address owner_) Ownable(owner_) {
        require(p.targetValue > 0, "Invalid target");
        require(p.totalInstallments > 0, "Invalid installments");
        require(p.totalDurationDays > 0, "Invalid duration");
        require(p.paymentToken != address(0), "PaymentToken zero");
        require(p.shareToken != address(0), "ShareToken zero");
        require(p.positionNft != address(0), "NFT zero");
        require(p.exitFeeBps <= 1000, "Fee too high");
        require(p.drawConsumer != address(0), "DrawConsumer zero");

        circleName = p.name;
        targetValue = p.targetValue;
        totalInstallments = p.totalInstallments;
        startTimestamp = p.startTimestamp;
        totalDurationDays = p.totalDurationDays;
        timePerRound = p.timePerRound;
        numberOfRounds = p.numRounds;
        numUsers = p.numUsers;
        exitFeeBps = p.exitFeeBps;
        paymentToken = p.paymentToken;
        shareToken = p.shareToken;
        positionNft = p.positionNft;
        creator = owner_;
        status = CircleStatus.ACTIVE;
        installmentAmount = p.targetValue / p.totalInstallments;
        quotaCapEarly = p.quotaCapEarly;
        quotaCapMiddle = p.quotaCapMiddle;
        quotaCapLate = p.quotaCapLate;

        uint256 totalSeconds = p.totalDurationDays * SECONDS_PER_DAY;
        uint256 phaseDuration = totalSeconds / 3;
        closeWindowEarly = p.startTimestamp + phaseDuration;
        closeWindowMiddle = p.startTimestamp + 2 * phaseDuration;
        closeWindowLate = p.startTimestamp + totalSeconds;

        drawConsumer = p.drawConsumer;
    }

    /// @param quotaId 0 = early, 1 = middle, 2 = late
    function getCloseWindowTimestamp(uint256 quotaId) public view returns (uint256) {
        _requireValidQuota(quotaId);
        if (quotaId == 0) return closeWindowEarly;
        if (quotaId == 1) return closeWindowMiddle;
        return closeWindowLate;
    }

    /// @notice Overload for enum. Returns close timestamp for the given phase.
    function getCloseWindowTimestamp(WindowPhase phase) external view returns (uint256) {
        return getCloseWindowTimestamp(uint256(phase));
    }

    /// @notice Returns the current phase given a timestamp. Before startTimestamp returns EARLY.
    function getCurrentPhase(uint256 timestamp) public view returns (WindowPhase) {
        if (timestamp < startTimestamp) return WindowPhase.EARLY;
        uint256 elapsed = timestamp - startTimestamp;
        uint256 totalSeconds = totalDurationDays * SECONDS_PER_DAY;
        uint256 phaseDuration = totalSeconds / 3;
        if (elapsed < phaseDuration) return WindowPhase.EARLY;
        if (elapsed < 2 * phaseDuration) return WindowPhase.MIDDLE;
        return WindowPhase.LATE;
    }

    /// @notice Rounds per phase (numRounds / 3). Must be divisible at creation.
    function getRoundsPerPhase() public view returns (uint256) {
        return numberOfRounds / 3;
    }

    /// @notice Start timestamp of the given phase (quotaId).
    function getPhaseStartTimestamp(uint256 quotaId) internal view returns (uint256) {
        uint256 totalSeconds = totalDurationDays * SECONDS_PER_DAY;
        uint256 phaseDuration = totalSeconds / 3;
        return startTimestamp + uint256(quotaId) * phaseDuration;
    }

    /// @notice Current round index (0-based) within the phase. Returns roundsPerPhase if past phase end.
    function getCurrentRoundIndex(uint256 quotaId) public view returns (uint256) {
        _requireValidQuota(quotaId);
        if (block.timestamp < startTimestamp) return 0;
        uint256 phaseStart = getPhaseStartTimestamp(quotaId);
        if (block.timestamp < phaseStart) return 0;
        uint256 elapsedInPhase = block.timestamp - phaseStart;
        uint256 roundIdx = elapsedInPhase / timePerRound;
        uint256 roundsPerPhase = getRoundsPerPhase();
        if (roundIdx >= roundsPerPhase) return roundsPerPhase - 1;
        return roundIdx;
    }

    /// @notice Sum of claim balances for eligible participants (excl. those who already redeemed in this window).
    function getCurrentWindowPot(uint256 quotaId, uint256 roundIndex) public view returns (uint256 totalPot) {
        _requireValidQuota(quotaId);
        uint256 roundsPerPhase = getRoundsPerPhase();
        if (roundIndex >= roundsPerPhase) revert CircleErrors.InvalidRoundIndex();
        for (uint256 i = 0; i < participants.length; i++) {
            address p = participants[i];
            if (hasRedeemedInWindow[quotaId][p]) continue;
            uint256 tokenId = participantToTokenId[p];
            if (tokenId == 0) continue;
            PositionNFT.PositionData memory pos = PositionNFT(positionNft).getPosition(tokenId);
            if (pos.quotaId != quotaId || pos.status != PositionNFT.Status.ACTIVE) continue;
            uint256 bal = IERC20(shareToken).balanceOf(p);
            if (bal == 0) continue;
            totalPot += bal;
        }
    }

    /// @notice Can close round when: (1) round deadline passed OR (2) pot sufficient, and sequential order.
    function canCloseWindow(uint256 quotaId, uint256 roundIndex) public view returns (bool) {
        _requireValidQuota(quotaId);
        uint256 roundsPerPhase = getRoundsPerPhase();
        if (roundIndex >= roundsPerPhase) return false;
        if (windowSnapshotted[quotaId][roundIndex]) return false;

        // Previous round in same window must be settled
        if (roundIndex > 0 && !windowRoundSettled[quotaId][roundIndex - 1]) return false;

        // All rounds of previous windows must be settled
        if (quotaId >= 1) {
            for (uint256 r = 0; r < roundsPerPhase; r++) {
                if (!windowRoundSettled[0][r]) return false;
            }
        }
        if (quotaId >= 2) {
            for (uint256 r = 0; r < roundsPerPhase; r++) {
                if (!windowRoundSettled[1][r]) return false;
            }
        }

        uint256 phaseStart = getPhaseStartTimestamp(quotaId);
        uint256 roundDeadline = phaseStart + (roundIndex + 1) * timePerRound;
        bool deadlinePassed = block.timestamp >= roundDeadline;
        uint256 currentPot = getCurrentWindowPot(quotaId, roundIndex);
        bool potSufficient = currentPot >= targetValue;

        return deadlinePassed || potSufficient;
    }

    /// @return Full draw order for the window round (for redeem order and off-chain use).
    function getDrawOrder(uint256 quotaId, uint256 roundIndex) external view returns (address[] memory) {
        uint256 requestId = quotaIdRoundToRequestId[quotaId][roundIndex];
        return IDrawConsumer(drawConsumer).getDrawOrder(requestId);
    }

    /// @return Whether the draw for this window round has been fulfilled by the VRF consumer.
    function drawCompleted(uint256 quotaId, uint256 roundIndex) public view returns (bool) {
        uint256 requestId = quotaIdRoundToRequestId[quotaId][roundIndex];
        return IDrawConsumer(drawConsumer).drawCompleted(requestId);
    }

    /// @return Participants snapshotted for that window round.
    function getWindowParticipants(uint256 quotaId, uint256 roundIndex) external view returns (address[] memory) {
        return windowParticipants[quotaId][roundIndex];
    }

    /// @param quotaId 0 = early, 1 = middle, 2 = late
    function deposit(uint256 quotaId) external nonReentrant() {
        _requireActive();
        _requireNotEnrolled(msg.sender);
        if (participants.length >= numUsers) revert CircleErrors.CircleFull();
        _requireValidQuota(quotaId);
        _requireBeforeCloseWindow(quotaId);
        _requireQuotaAvailable(quotaId);

        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), installmentAmount);

        _incrementQuotaFilled(quotaId);

        uint256 tokenId = PositionNFT(positionNft).mint(msg.sender, PositionNFT.PositionData({
            quotaId: quotaId,
            targetValue: targetValue,
            totalInstallments: totalInstallments,
            paidInstallments: 1,
            totalPaid: installmentAmount,
            status: PositionNFT.Status.ACTIVE
        }));

        participantToTokenId[msg.sender] = tokenId;
        participants.push(msg.sender);
        activeParticipantCount++;
        snapshotTimestamp = block.timestamp;
        snapshotBalance += installmentAmount;
        snapshotClaimsSupply += installmentAmount;

        ERC20Claim(shareToken).mint(msg.sender, installmentAmount);

        emit ParticipantEnrolled(msg.sender, tokenId, installmentAmount);
    }

    function _quotaCapacity(uint256 quotaId) internal view returns (uint256) {
        if (quotaId == 0) return quotaCapEarly;
        if (quotaId == 1) return quotaCapMiddle;
        return quotaCapLate;
    }

    function _quotaFilled(uint256 quotaId) internal view returns (uint256) {
        if (quotaId == 0) return quotaFilledEarly;
        if (quotaId == 1) return quotaFilledMiddle;
        return quotaFilledLate;
    }

    function _incrementQuotaFilled(uint256 quotaId) internal {
        if (quotaId == 0) quotaFilledEarly++;
        else if (quotaId == 1) quotaFilledMiddle++;
        else quotaFilledLate++;
    }

    /// @notice Pay next installment within the same quota window.
    /// Participant remains in their original window and continues participating in future draws.
    function payInstallment() external nonReentrant {
        _requireActive();
        uint256 tokenId = _requireEnrolled(msg.sender);

        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), installmentAmount);

        PositionNFT.PositionData memory positionData = PositionNFT(positionNft).getPosition(tokenId);
        if (positionData.paidInstallments >= positionData.totalInstallments) revert CircleErrors.PositionFullyPaid();

        if (positionData.status != PositionNFT.Status.ACTIVE) revert CircleErrors.PositionNotActive();

        // Participant stays in the same quotaId - no window changes
        positionData.paidInstallments++;
        positionData.totalPaid += installmentAmount;

        snapshotBalance += installmentAmount;
        snapshotClaimsSupply += installmentAmount;

        PositionNFT(positionNft).updatePaid(tokenId, positionData.paidInstallments, positionData.totalPaid);
        ERC20Claim(shareToken).mint(msg.sender, installmentAmount);

        if (positionData.paidInstallments >= positionData.totalInstallments) {
            PositionNFT(positionNft).setStatus(tokenId, PositionNFT.Status.CLOSED);
        }

        emit InstallmentPaid(msg.sender, tokenId, installmentAmount, positionData.totalPaid);
    }

    function exitEarly(uint256 claimAmount) external nonReentrant() {
        _requireActive();
        uint256 tokenId = _requireEnrolled(msg.sender);

        PositionNFT.PositionData memory positionData = PositionNFT(positionNft).getPosition(tokenId);
        if (positionData.status != PositionNFT.Status.ACTIVE) revert CircleErrors.PositionNotActive();

        if (claimAmount == 0) revert CircleErrors.ZeroAmount();
        IERC20 claimToken = IERC20(shareToken);
        if (claimToken.balanceOf(msg.sender) < claimAmount) revert CircleErrors.InsufficientClaims();

        uint256 feeAmount = (claimAmount * exitFeeBps) / 10_000;
        uint256 netAmount = claimAmount - feeAmount;
        if (IERC20(paymentToken).balanceOf(address(this)) < netAmount) revert CircleErrors.InsufficientBalance();
        if (snapshotBalance < netAmount) revert CircleErrors.InsufficientBalance();
        if (snapshotClaimsSupply < claimAmount) revert CircleErrors.InsufficientSnapshot();

        snapshotBalance -= netAmount;
        snapshotClaimsSupply -= claimAmount;
        activeParticipantCount--;

        claimToken.safeTransferFrom(msg.sender, address(this), claimAmount);
        ERC20Claim(shareToken).burn(address(this), claimAmount);
        PositionNFT(positionNft).setStatus(tokenId, PositionNFT.Status.EXITED);
        participantToTokenId[msg.sender] = 0;

        IERC20(paymentToken).safeTransfer(msg.sender, netAmount);

        emit EarlyExit(msg.sender, tokenId, claimAmount, feeAmount, netAmount);
    }

    function isEnrolled(address participant) public view returns (bool) {
        return participantToTokenId[participant] != 0;
    }

    /// @notice Snapshot a payout window round and request VRF draw. Callable when canCloseWindow(quotaId, roundIndex).
    /// @param quotaId 0 = early, 1 = middle, 2 = late
    /// @param roundIndex 0-based round within the phase
    function requestCloseWindow(uint256 quotaId, uint256 roundIndex) external nonReentrant {
        _requireActive();
        _requireValidQuota(quotaId);
        uint256 roundsPerPhase = getRoundsPerPhase();
        if (roundIndex >= roundsPerPhase) revert CircleErrors.InvalidRoundIndex();
        if (!canCloseWindow(quotaId, roundIndex)) revert CircleErrors.WindowNotReadyToClose();
        if (windowSnapshotted[quotaId][roundIndex]) revert CircleErrors.AlreadySnapshotted();

        uint256 participantCount = _snapshotWindow(quotaId, roundIndex);
        ERC20Claim(shareToken).setTransfersFrozen(true);

        _requestDraw(quotaId, roundIndex);

        emit WindowSnapshotted(quotaId, roundIndex, block.timestamp, participantCount);
    }

    /// @notice Redeem after draw: single contemplado (first in draw order) receives full round pot.
    /// Non-selected participants keep their claims for future rounds.
    function redeem(uint256 quotaId, uint256 roundIndex) external nonReentrant {
        _requireValidQuota(quotaId);
        uint256 roundsPerPhase = getRoundsPerPhase();
        if (roundIndex >= roundsPerPhase) revert CircleErrors.InvalidRoundIndex();
        if (windowRoundSettled[quotaId][roundIndex]) revert CircleErrors.AlreadySettled();
        if (!drawCompleted(quotaId, roundIndex)) revert CircleErrors.NotSnapshotted();

        uint256 requestId = quotaIdRoundToRequestId[quotaId][roundIndex];
        address[] memory order = IDrawConsumer(drawConsumer).getDrawOrder(requestId);
        if (order.length == 0) revert CircleErrors.InvalidParameters();
        if (msg.sender != order[0]) revert CircleErrors.NotSelected();

        uint256 tokenId = _requireEnrolled(msg.sender);

        uint256 potAmount = windowTotalPot[quotaId][roundIndex];
        if (potAmount == 0) revert CircleErrors.ZeroAmount();
        if (IERC20(paymentToken).balanceOf(address(this)) < potAmount) revert CircleErrors.InsufficientBalance();
        if (snapshotBalance < potAmount) revert CircleErrors.InsufficientBalance();

        windowRoundSettled[quotaId][roundIndex] = true;
        hasRedeemedInWindow[quotaId][msg.sender] = true;
        snapshotBalance -= potAmount;
        snapshotClaimsSupply -= potAmount;

        // Winner: pull and burn only their own claims
        uint256 winnerClaimAmount = windowSnapshotBalance[quotaId][roundIndex][msg.sender];
        if (winnerClaimAmount > 0) {
            IERC20(shareToken).safeTransferFrom(msg.sender, address(this), winnerClaimAmount);
            ERC20Claim(shareToken).burn(address(this), winnerClaimAmount);
        }

        IERC20(paymentToken).safeTransfer(msg.sender, potAmount);

        bytes32 proof = keccak256(abi.encodePacked(quotaId, roundIndex, msg.sender, potAmount, block.timestamp));
        emit Redeemed(msg.sender, tokenId, quotaId, potAmount, proof);
    }

    /// @return Full pot (payment token) the single contemplado receives for this round; 0 if round already settled.
    function getWindowPotShare(uint256 quotaId, uint256 roundIndex) external view returns (uint256) {
        if (windowRoundSettled[quotaId][roundIndex]) return 0;
        return windowTotalPot[quotaId][roundIndex];
    }

    function _requireActive() internal view {
        if (status != CircleStatus.ACTIVE) revert CircleErrors.CircleNotActive();
    }

    function _requireValidQuota(uint256 quotaId) internal pure {
        if (quotaId > MAX_QUOTA_ID) revert CircleErrors.InvalidQuota();
    }

    function _requireBeforeCloseWindow(uint256 quotaId) internal view {
        if (block.timestamp > getCloseWindowTimestamp(quotaId)) revert CircleErrors.JoinAfterDeadline();
    }

    function _requireAfterCloseWindow(uint256 quotaId) internal view {
        if (block.timestamp < getCloseWindowTimestamp(quotaId)) revert CircleErrors.InvalidParameters();
    }

    function _requireNotEnrolled(address participant) internal view {
        if (participantToTokenId[participant] != 0) revert CircleErrors.AlreadyEnrolled();
    }

    function _requireEnrolled(address participant) internal view returns (uint256 tokenId) {
        tokenId = participantToTokenId[participant];
        if (tokenId == 0) revert CircleErrors.NotEnrolled();
    }

    function _requireQuotaAvailable(uint256 quotaId) internal view {
        if (_quotaFilled(quotaId) >= _quotaCapacity(quotaId)) revert CircleErrors.QuotaFull();
    }

    function _snapshotWindow(uint256 quotaId, uint256 roundIndex) internal returns (uint256 participantCount) {
        address[] storage list = windowParticipants[quotaId][roundIndex];
        uint256 totalPot;
        for (uint256 i = 0; i < participants.length; i++) {
            address p = participants[i];
            if (hasRedeemedInWindow[quotaId][p]) continue;
            uint256 tokenId = participantToTokenId[p];
            if (tokenId == 0) continue;
            PositionNFT.PositionData memory pos = PositionNFT(positionNft).getPosition(tokenId);
            if (pos.quotaId != quotaId || pos.status != PositionNFT.Status.ACTIVE) continue;
            uint256 bal = IERC20(shareToken).balanceOf(p);
            if (bal == 0) continue;
            list.push(p);
            windowSnapshotBalance[quotaId][roundIndex][p] = bal;
            totalPot += bal;
        }
        if (list.length == 0) revert CircleErrors.NoActiveParticipants();

        windowTotalPot[quotaId][roundIndex] = totalPot;
        windowSnapshotted[quotaId][roundIndex] = true;
        windowSnapshotTimestamp[quotaId][roundIndex] = block.timestamp;

        return list.length;
    }

    function _requestDraw(uint256 quotaId, uint256 roundIndex) internal {
        address[] storage list = windowParticipants[quotaId][roundIndex];
        uint256 n = list.length;
        address[] memory participantsList = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            participantsList[i] = list[i];
        }
        uint256 requestId = IDrawConsumer(drawConsumer).requestDraw(quotaId, participantsList);
        quotaIdRoundToRequestId[quotaId][roundIndex] = requestId;
    }

    receive() external payable {
        revert CircleErrors.InvalidParameters();
    }
}
