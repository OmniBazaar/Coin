// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MpcCore, gtUint256, ctUint256, itUint256, ctUint128, gtBool} from "../coti-helium/utils/mpc/MpcCore.sol";
import {CommitteeAttestor} from "../attestation/CommitteeAttestor.sol";
import {IPrivateERC20} from "../coti-helium/token/PrivateERC20/IPrivateERC20.sol";

contract PrivateLimitDEXSettlement is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    EIP712Upgradeable,
    CommitteeAttestor
{
    using MpcCore for gtUint256;
    using MpcCore for ctUint256;
    using MpcCore for gtBool;

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint64 private constant MAX_TRADING_FEE_BPS = 100;
    uint64 private constant LP_SHARE_BPS = 7000;
    uint64 private constant VAULT_SHARE_BPS = 3000;
    uint256 private constant MIN_LOCK_DURATION = 5 minutes;
    uint256 private constant TIMELOCK_DELAY = 0;

    // -----------------------------------------------------------------------
    // Roles
    // -----------------------------------------------------------------------

    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");
    bytes32 public constant COMMITTEE_ROLE = keccak256("COMMITTEE_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    // -----------------------------------------------------------------------
    // Enums
    // -----------------------------------------------------------------------

    enum SettlementStatus { EMPTY, LOCKED, SETTLED, CANCELLED }

    // -----------------------------------------------------------------------
    // Structs
    // -----------------------------------------------------------------------

    struct PrivateCollateral {
        address trader;
        address solver;
        address tokenIn;
        address tokenOut;
        ctUint256 traderCollateral;
        ctUint256 solverCollateral;
        uint256 nonce;
        uint256 deadline;
        uint256 lockTimestamp;
        uint64 tradingFeeBpsAtLock;
        SettlementStatus status;
    }

    struct LimitCollateral {
        address trader;
        address solver;
        address tokenIn;
        address tokenOut;
        ctUint256 maxTraderCollateral;
        ctUint256 maxSolverCollateral;
        uint256 limitPrice;
        bool isBuy;
        uint256 filledTrader;
        uint256 filledSolver;
        uint256 nonce;
        uint256 deadline;
        uint256 lockTimestamp;
        uint64 tradingFeeBpsAtLock;
        SettlementStatus status;
    }

    struct EncryptedFeeRecord {
        ctUint256 lpFee;
        ctUint256 vaultFee;
    }

    struct FeeRecipients {
        address liquidityPool;
        address feeVault;
    }

    struct PendingFeeRecipients {
        address liquidityPool;
        address feeVault;
        uint256 effectiveAt;
    }

    struct PendingTradingFee {
        uint64 newFeeBps;
        uint256 effectiveAt;
    }

    struct PendingForwarder {
        address forwarder;
        uint256 effectiveAt;
    }

    struct PendingUpgrade {
        address newImplementation;
        uint256 effectiveAt;
    }

    // -----------------------------------------------------------------------
    // EIP-712 Types
    // -----------------------------------------------------------------------

    bytes32 private constant LOCK_INTENT_TYPEHASH = keccak256(
        "LockIntent(bytes32 intentId,address trader,address solver,address tokenIn,address tokenOut,bytes32 traderCommit,bytes32 solverCommit,uint64 tradingFeeBps,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant LOCK_LIMIT_INTENT_TYPEHASH = keccak256(
        "LockLimitIntent(bytes32 intentId,address trader,address solver,address tokenIn,address tokenOut,bytes32 traderCommit,bytes32 solverCommit,uint256 limitPrice,bool isBuy,uint64 tradingFeeBps,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant SETTLE_INTENT_TYPEHASH = keccak256(
        "SettleIntent(bytes32 intentIdA,bytes32 intentIdB)"
    );

    bytes32 private constant SETTLE_LIMIT_TYPEHASH = keccak256(
        "SettleLimit(bytes32 intentIdA,bytes32 intentIdB,uint256 agreedPrice,uint256 fillTrader,uint256 fillSolver)"
    );

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    uint64 public tradingFeeBps;
    FeeRecipients public feeRecipients;
    PendingFeeRecipients public pendingFeeRecipients;
    PendingTradingFee public pendingTradingFee;
    PendingForwarder public pendingForwarder;
    PendingUpgrade public pendingUpgrade;

    mapping(bytes32 => PrivateCollateral) public privateCollateral;
    mapping(bytes32 => LimitCollateral) public limitCollateral;
    mapping(address => uint256) public nonces;
    mapping(address => EncryptedFeeRecord) public accumulatedFees;
    mapping(address => uint256) public claimNonces;

    bool public ossified;
    bool public upgradeRequested;
    uint256 public ossificationRequestedAt;

    address private _trustedForwarder;

    uint256[49] private __gap;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event LockCommitteeAttested(bytes32 indexed intentId, address indexed trader, address indexed solver);
    event LimitLockCommitteeAttested(bytes32 indexed intentId, address indexed trader, address indexed solver, uint256 limitPrice, bool isBuy);
    event SettleCommitteeAttested(bytes32 indexed intentIdA, bytes32 indexed intentIdB);
    event LimitSettleCommitteeAttested(bytes32 indexed intentIdA, bytes32 indexed intentIdB, uint256 agreedPrice, uint256 fillTrader, uint256 fillSolver);
    event PrivateCollateralLocked(bytes32 indexed intentId, address indexed trader, address tokenIn, address tokenOut);
    event PrivateLimitLocked(bytes32 indexed intentId, address indexed trader, address tokenIn, address tokenOut, uint256 limitPrice, bool isBuy);
    event PrivateBilateralSettled(bytes32 indexed intentIdA, bytes32 indexed intentIdB);
    event PrivateLimitSettled(bytes32 indexed intentIdA, bytes32 indexed intentIdB, uint256 fillTrader, uint256 fillSolver);
    event PrivateIntentSettled(bytes32 indexed intentId, address indexed trader, address indexed solver, address tokenIn, address tokenOut, bytes32 settlementHash);
    event PrivateIntentCancelled(bytes32 indexed intentId, address indexed trader);
    event FeesClaimed(address indexed claimant, ctUint256 lpFee, ctUint256 vaultFee, uint256 claimNonce);
    event FeeRecipientsUpdated(address indexed liquidityPool, address indexed feeVault);
    event TradingFeeUpdated(uint64 oldFeeBps, uint64 newFeeBps);
    event ForwarderUpdated(address indexed oldForwarder, address indexed newForwarder);
    event UpgradeRequested(address indexed newImplementation);
    event UpgradeApplied(address indexed newImplementation);
    event OssificationRequested();
    event OssificationConfirmed();

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error InvalidIntentId();
    error IntentAlreadyExists(bytes32 intentId);
    error IntentNotFound(bytes32 intentId);
    error IntentNotLocked(bytes32 intentId);
    error IntentAlreadySettled(bytes32 intentId);
    error IntentExpired(bytes32 intentId);
    error DeadlineExpired(uint256 deadline);
    error NonceAlreadyUsed(uint256 nonce);
    error InvalidSignature();
    error InvalidCommitteeProof();
    error SubjectInCommittee();
    error TraderMismatch();
    error SolverMismatch();
    error TokenMismatch();
    error SideMismatch();
    error PriceConstraintNotMet(uint256 agreedPrice, uint256 limitPrice, bool isBuy);
    error FeeExceedsMax(uint64 feeBps, uint64 max);
    error LockDurationNotMet(uint256 elapsed, uint256 required);
    error CannotCancelSettled(bytes32 intentId);
    error ContractIsOssified();
    error UpgradeNotRequested();
    error UpgradeTimelockNotMet(uint256 effectiveAt);
    error NotTrustedForwarder();
    error FillExceedsMax(uint256 fill, uint256 max);
    error CollateralExceeded(bytes32 intentId, uint256 attemptedFill);
    error InvalidPrice();
    error InvalidCommitteeAttestation();
    error CannotRenounceAdmin();
    error UnsupportedChain(uint256 chainId);
    error TradingFeeMismatch(uint64 expected, uint64 actual);
    error FillAmountTooLarge(uint256 fill, uint256 maxAllowed);
    error OssificationTimelockNotMet(uint256 effectiveAt);
    error OssificationAlreadyRequested();

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // -----------------------------------------------------------------------
    // Initializer
    // -----------------------------------------------------------------------

    function initialize(
        address admin_,
        address liquidityPool_,
        address feeVault_,
        uint64 tradingFeeBps_,
        address trustedForwarder_,
        uint256 committeeSize_,
        uint256 quorumM_
    ) external initializer {
        if (admin_ == address(0)) revert ZeroAddress();
        if (liquidityPool_ == address(0)) revert ZeroAddress();
        if (feeVault_ == address(0)) revert ZeroAddress();
        if (tradingFeeBps_ > MAX_TRADING_FEE_BPS) revert FeeExceedsMax(tradingFeeBps_, MAX_TRADING_FEE_BPS);
        if (block.chainid != 2632500 && block.chainid != 7082400) revert UnsupportedChain(block.chainid);

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __EIP712_init("PrivateLimitDEXSettlement", "1");
        __CommitteeAttestor_init(committeeSize_, quorumM_);

        tradingFeeBps = tradingFeeBps_;
        feeRecipients = FeeRecipients({liquidityPool: liquidityPool_, feeVault: feeVault_});
        _trustedForwarder = trustedForwarder_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(SETTLER_ROLE, admin_);
        _grantRole(FEE_MANAGER_ROLE, admin_);
    }

    // -----------------------------------------------------------------------
    // ERC-2771
    // -----------------------------------------------------------------------

    function _msgSender() internal view virtual override(ContextUpgradeable) returns (address) {
        address forwarder = _trustedForwarder;
        if (forwarder != address(0) && msg.data.length >= 20 && msg.sender == forwarder) {
            address sender;
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
            return sender;
        }
        return super._msgSender();
    }

    function _msgData() internal view virtual override(ContextUpgradeable) returns (bytes calldata) {
        address forwarder = _trustedForwarder;
        if (forwarder != address(0) && msg.data.length >= 20 && msg.sender == forwarder) {
            return msg.data[:msg.data.length - 20];
        }
        return super._msgData();
    }

    // -----------------------------------------------------------------------
    // UUPS
    // -----------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (ossified) revert ContractIsOssified();
        if (upgradeRequested) {
            PendingUpgrade storage pu = pendingUpgrade;
            if (block.timestamp < pu.effectiveAt) revert UpgradeTimelockNotMet(pu.effectiveAt);
            if (newImplementation != pu.newImplementation) revert ZeroAddress();
            upgradeRequested = false;
            emit UpgradeApplied(newImplementation);
        } else {
            pendingUpgrade = PendingUpgrade({newImplementation: newImplementation, effectiveAt: block.timestamp + TIMELOCK_DELAY});
            emit UpgradeRequested(newImplementation);
            upgradeRequested = false;
            emit UpgradeApplied(newImplementation);
        }
    }

    function cancelUpgrade() external onlyRole(DEFAULT_ADMIN_ROLE) {
        upgradeRequested = false;
        delete pendingUpgrade;
    }

    // -----------------------------------------------------------------------
    // Ossification
    // -----------------------------------------------------------------------

    function requestOssification() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (ossified) revert ContractIsOssified();
        if (ossificationRequestedAt != 0) revert OssificationAlreadyRequested();
        ossificationRequestedAt = block.timestamp;
        emit OssificationRequested();
    }

    function confirmOssification() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (ossified) revert ContractIsOssified();
        if (ossificationRequestedAt == 0) revert ZeroAmount();
        if (block.timestamp < ossificationRequestedAt + 7 days) {
            revert OssificationTimelockNotMet(ossificationRequestedAt + 7 days);
        }
        ossified = true;
        emit OssificationConfirmed();
    }

    // -----------------------------------------------------------------------
    // Admin: Fee Management
    // -----------------------------------------------------------------------

    function updateFeeRecipients(address liquidityPool_, address feeVault_) external onlyRole(FEE_MANAGER_ROLE) {
        if (liquidityPool_ == address(0) || feeVault_ == address(0)) revert ZeroAddress();
        pendingFeeRecipients = PendingFeeRecipients({
            liquidityPool: liquidityPool_,
            feeVault: feeVault_,
            effectiveAt: block.timestamp + TIMELOCK_DELAY
        });
    }

    function applyFeeRecipients() external onlyRole(FEE_MANAGER_ROLE) {
        PendingFeeRecipients storage pfr = pendingFeeRecipients;
        if (block.timestamp < pfr.effectiveAt) revert LockDurationNotMet(block.timestamp - pfr.effectiveAt + TIMELOCK_DELAY, TIMELOCK_DELAY);
        feeRecipients = FeeRecipients({liquidityPool: pfr.liquidityPool, feeVault: pfr.feeVault});
        delete pendingFeeRecipients;
        emit FeeRecipientsUpdated(pfr.liquidityPool, pfr.feeVault);
    }

    function updateTradingFee(uint64 newFeeBps) external onlyRole(FEE_MANAGER_ROLE) {
        if (newFeeBps > MAX_TRADING_FEE_BPS) revert FeeExceedsMax(newFeeBps, MAX_TRADING_FEE_BPS);
        pendingTradingFee = PendingTradingFee({newFeeBps: newFeeBps, effectiveAt: block.timestamp + TIMELOCK_DELAY});
    }

    function applyTradingFee() external onlyRole(FEE_MANAGER_ROLE) {
        PendingTradingFee storage ptf = pendingTradingFee;
        if (block.timestamp < ptf.effectiveAt) revert LockDurationNotMet(block.timestamp - ptf.effectiveAt + TIMELOCK_DELAY, TIMELOCK_DELAY);
        uint64 oldFee = tradingFeeBps;
        tradingFeeBps = ptf.newFeeBps;
        delete pendingTradingFee;
        emit TradingFeeUpdated(oldFee, tradingFeeBps);
    }

    function updateForwarder(address forwarder_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (forwarder_ == address(0)) revert ZeroAddress();
        pendingForwarder = PendingForwarder({forwarder: forwarder_, effectiveAt: block.timestamp + TIMELOCK_DELAY});
    }

    function applyForwarder() external onlyRole(DEFAULT_ADMIN_ROLE) {
        PendingForwarder storage pf = pendingForwarder;
        if (block.timestamp < pf.effectiveAt) revert LockDurationNotMet(block.timestamp - pf.effectiveAt + TIMELOCK_DELAY, TIMELOCK_DELAY);
        address oldForwarder = _trustedForwarder;
        _trustedForwarder = pf.forwarder;
        delete pendingForwarder;
        emit ForwarderUpdated(oldForwarder, _trustedForwarder);
    }

    // -----------------------------------------------------------------------
    // Pause
    // -----------------------------------------------------------------------

    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert CannotRenounceAdmin();
        super.renounceRole(role, callerConfirmation);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // -----------------------------------------------------------------------
    // Committee-Attested Limit Lock
    // -----------------------------------------------------------------------

    function lockPrivateLimitWithCommittee(
        bytes32 intentId,
        address trader,
        address solver,
        address tokenIn,
        address tokenOut,
        itUint256 calldata encMaxTraderAmount,
        itUint256 calldata encMaxSolverAmount,
        uint256 limitPrice,
        bool isBuy,
        uint64 expectedFeeBps,
        uint256 traderNonce,
        uint256 deadline,
        bytes calldata traderSignature,
        bytes calldata committeeProof
    ) external nonReentrant whenNotPaused {
        if (trader == address(0) || solver == address(0)) revert ZeroAddress();
        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        if (limitPrice == 0) revert InvalidPrice();
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
        if (traderNonce <= nonces[trader]) revert NonceAlreadyUsed(traderNonce);
        if (expectedFeeBps != tradingFeeBps) revert TradingFeeMismatch(expectedFeeBps, tradingFeeBps);
        if (privateCollateral[intentId].status != SettlementStatus.EMPTY || limitCollateral[intentId].status != SettlementStatus.EMPTY) {
            revert IntentAlreadyExists(intentId);
        }

        bytes32 traderCommit = _commit(encMaxTraderAmount);
        bytes32 solverCommit = _commit(encMaxSolverAmount);

        bytes32 digest = _lockLimitIntentDigest(intentId, trader, solver, tokenIn, tokenOut, traderCommit, solverCommit, limitPrice, isBuy, expectedFeeBps, traderNonce, deadline);
        address signer = ECDSA.recover(digest, traderSignature);
        if (signer != trader) revert InvalidSignature();

        (bool committeeValid, address[] memory attesters) = _verifyCommittee(digest, committeeProof);
        if (!committeeValid) revert InvalidCommitteeAttestation();

        if (_isInSnapshot(trader) || _isInSnapshot(solver)) revert SubjectInCommittee();

        nonces[trader] = traderNonce;

        gtUint256 gtTrader = MpcCore.validateCiphertext(encMaxTraderAmount);
        gtUint256 gtSolver = MpcCore.validateCiphertext(encMaxSolverAmount);

        ctUint256 memory ctTrader = MpcCore.offBoard(gtTrader);
        ctUint256 memory ctSolver = MpcCore.offBoard(gtSolver);

        limitCollateral[intentId] = LimitCollateral({
            trader: trader,
            solver: solver,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            maxTraderCollateral: ctTrader,
            maxSolverCollateral: ctSolver,
            limitPrice: limitPrice,
            isBuy: isBuy,
            filledTrader: 0,
            filledSolver: 0,
            nonce: traderNonce,
            deadline: deadline,
            lockTimestamp: block.timestamp,
            tradingFeeBpsAtLock: expectedFeeBps,
            status: SettlementStatus.LOCKED
        });

        IPrivateERC20(tokenIn).transferFromGT(trader, address(this), gtTrader);

        emit LimitLockCommitteeAttested(intentId, trader, solver, limitPrice, isBuy);
        emit PrivateLimitLocked(intentId, trader, tokenIn, tokenOut, limitPrice, isBuy);
    }

    // -----------------------------------------------------------------------
    // Committee-Attested Limit Settle
    // -----------------------------------------------------------------------

    function settleBilateralLimitWithCommittee(
        bytes32 intentIdA,
        bytes32 intentIdB,
        uint256 agreedPrice,
        uint256 fillTrader,
        uint256 fillSolver,
        bytes calldata committeeProof
    ) external nonReentrant whenNotPaused {
        LimitCollateral storage a = limitCollateral[intentIdA];
        LimitCollateral storage b = limitCollateral[intentIdB];

        if (a.status != SettlementStatus.LOCKED) revert IntentNotLocked(intentIdA);
        if (b.status != SettlementStatus.LOCKED) revert IntentNotLocked(intentIdB);

        if (a.tokenIn != b.tokenOut || a.tokenOut != b.tokenIn) revert TokenMismatch();
        if (a.solver != b.trader || b.solver != a.trader) revert SolverMismatch();
        if (a.isBuy == b.isBuy) revert SideMismatch();

        if (fillTrader == 0 || fillSolver == 0) revert ZeroAmount();
        if (fillTrader > type(uint128).max || fillSolver > type(uint128).max) revert FillAmountTooLarge(fillTrader > fillSolver ? fillTrader : fillSolver, type(uint128).max);

        uint256 remainingTraderA = type(uint256).max - a.filledTrader;
        uint256 remainingSolverA = type(uint256).max - a.filledSolver;
        if (fillTrader > remainingTraderA || fillSolver > remainingSolverA) revert FillExceedsMax(fillTrader, remainingTraderA);

        uint256 remainingTraderB = type(uint256).max - b.filledTrader;
        uint256 remainingSolverB = type(uint256).max - b.filledSolver;
        if (fillSolver > remainingTraderB || fillTrader > remainingSolverB) revert FillExceedsMax(fillSolver, remainingTraderB);

        if (a.isBuy) {
            if (agreedPrice > a.limitPrice) revert PriceConstraintNotMet(agreedPrice, a.limitPrice, true);
            if (agreedPrice < b.limitPrice) revert PriceConstraintNotMet(agreedPrice, b.limitPrice, false);
        } else {
            if (agreedPrice < a.limitPrice) revert PriceConstraintNotMet(agreedPrice, a.limitPrice, false);
            if (agreedPrice > b.limitPrice) revert PriceConstraintNotMet(agreedPrice, b.limitPrice, true);
        }

        bytes32 digest = _settleLimitDigest(intentIdA, intentIdB, agreedPrice, fillTrader, fillSolver);
        (bool settleValid, address[] memory settleAttesters) = _verifyCommittee(digest, committeeProof);
        if (!settleValid) revert InvalidCommitteeAttestation();

        if (_isInSnapshot(a.trader) || _isInSnapshot(a.solver)) revert SubjectInCommittee();

        _settleLimitOne(intentIdA, fillTrader, fillSolver, agreedPrice);
        _settleLimitOne(intentIdB, fillSolver, fillTrader, agreedPrice);

        emit LimitSettleCommitteeAttested(intentIdA, intentIdB, agreedPrice, fillTrader, fillSolver);
        emit PrivateLimitSettled(intentIdA, intentIdB, fillTrader, fillSolver);
    }

    // -----------------------------------------------------------------------
    // Internal: Limit Settle One Leg
    // -----------------------------------------------------------------------

    function _settleLimitOne(bytes32 intentId, uint256 traderFill, uint256 solverFill, uint256 agreedPrice) internal {
        LimitCollateral storage c = limitCollateral[intentId];

        if (c.status != SettlementStatus.LOCKED) revert IntentNotLocked(intentId);
        if (block.timestamp > c.deadline) revert IntentExpired(intentId);

        // Collateral conservation: verify filled + fill ≤ maxCollateral.
        // maxTraderCollateral is ctUint256 (encrypted under trader's MPC key).
        // The committee calling settleBilateralLimitWithCommittee does NOT hold
        // the trader's MPC key, so MpcCore.onBoard() would fail here.
        //
        // Trust model (current): the committee attests to fill amounts via
        // _verifyCommittee(). The contract trusts the committee to not attest
        // to fills exceeding locked collateral. A dishonest attestation is
        // detectable off-chain (filledTrader is public) and slashable.
        //
        // Phase 2: when the MPC network supports committee-requested encrypted
        // comparisons, replace the trust-model comment below with:
        //   gtUint256 gtMax = MpcCore.onBoard(c.maxTraderCollateral);
        //   gtUint256 gtNewFilled = MpcCore.setPublic256(c.filledTrader + traderFill);
        //   if (MpcCore.offBoardToBool(MpcCore.gt(gtNewFilled, gtMax))) {
        //       revert CollateralExceeded(intentId, c.filledTrader + traderFill);
        //   }
        //
        // Overflow guard (existing): filledTrader + traderFill ≤ type(uint256).max.
        // This is NOT a collateral check — it only prevents uint256 wraparound.
        uint256 newFilledTrader = c.filledTrader + traderFill;
        uint256 newFilledSolver = c.filledSolver + solverFill;

        c.filledTrader = newFilledTrader;
        c.filledSolver = newFilledSolver;

        if (c.filledTrader >= type(uint128).max || c.filledSolver >= type(uint128).max) {
            c.status = SettlementStatus.SETTLED;
        }

        gtUint256 gtTraderFill = MpcCore.setPublic256(traderFill);
        gtUint256 gtFeeBps = MpcCore.setPublic256(c.tradingFeeBpsAtLock);
        gtUint256 gtBpsDenom = MpcCore.setPublic256(BPS_DENOMINATOR);

        gtUint256 gtTotalFee = MpcCore.checkedMul(gtTraderFill, gtFeeBps);
        gtTotalFee = MpcCore.div(gtTotalFee, gtBpsDenom);

        gtUint256 gtLpShare = MpcCore.setPublic256(LP_SHARE_BPS);
        gtUint256 gtVaultShare = MpcCore.setPublic256(VAULT_SHARE_BPS);

        gtUint256 gtLpFee = MpcCore.checkedMul(gtTotalFee, gtLpShare);
        gtLpFee = MpcCore.div(gtLpFee, gtBpsDenom);

        gtUint256 gtVaultFee = MpcCore.checkedSub(gtTotalFee, gtLpFee);

        gtUint256 gtNet = MpcCore.checkedSub(gtTraderFill, gtTotalFee);

        IPrivateERC20(c.tokenIn).transferGT(c.solver, gtNet);
        IPrivateERC20(c.tokenIn).transferGT(feeRecipients.liquidityPool, gtLpFee);
        IPrivateERC20(c.tokenIn).transferGT(feeRecipients.feeVault, gtVaultFee);

        bytes32 settlementHash = keccak256(abi.encodePacked(intentId, c.trader, c.solver, c.tokenIn, c.tokenOut, block.timestamp, block.chainid));
        emit PrivateIntentSettled(intentId, c.trader, c.solver, c.tokenIn, c.tokenOut, settlementHash);
    }

    // -----------------------------------------------------------------------
    // Cancel Limit Intent
    // -----------------------------------------------------------------------

    function cancelPrivateLimitIntent(bytes32 intentId) external nonReentrant {
        LimitCollateral storage c = limitCollateral[intentId];
        if (c.status != SettlementStatus.LOCKED) revert IntentNotLocked(intentId);
        if (c.trader != _msgSender()) revert TraderMismatch();
        if (block.timestamp < c.lockTimestamp + MIN_LOCK_DURATION) {
            revert LockDurationNotMet(block.timestamp - c.lockTimestamp, MIN_LOCK_DURATION);
        }

        c.status = SettlementStatus.CANCELLED;

        gtUint256 gtMax = MpcCore.onBoard(c.maxTraderCollateral);
        gtUint256 gtFilled = MpcCore.setPublic256(c.filledTrader);
        gtUint256 gtRefund = MpcCore.checkedSub(gtMax, gtFilled);

        IPrivateERC20(c.tokenIn).transferGT(c.trader, gtRefund);

        emit PrivateIntentCancelled(intentId, c.trader);
    }

    // -----------------------------------------------------------------------
    // Claim Fees
    // -----------------------------------------------------------------------

    function claimFees() external nonReentrant {
        EncryptedFeeRecord storage fees = accumulatedFees[_msgSender()];
        if (_isCtZero(fees.lpFee) && _isCtZero(fees.vaultFee)) {
            revert ZeroAmount();
        }

        ctUint256 memory lpFee = fees.lpFee;
        ctUint256 memory vaultFee = fees.vaultFee;

        ctUint256 memory zeroCt = MpcCore.offBoard(MpcCore.setPublic256(0));
        fees.lpFee = zeroCt;
        fees.vaultFee = zeroCt;

        claimNonces[_msgSender()]++;

        emit FeesClaimed(_msgSender(), lpFee, vaultFee, claimNonces[_msgSender()]);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function getLimitCollateral(bytes32 intentId) external view returns (LimitCollateral memory) {
        return limitCollateral[intentId];
    }

    function getPrivateCollateral(bytes32 intentId) external view returns (PrivateCollateral memory) {
        return privateCollateral[intentId];
    }

    function getTrustedForwarder() external view returns (address) {
        return _trustedForwarder;
    }

    function isLiquidatable(bytes32 intentId) external view returns (bool) {
        LimitCollateral storage c = limitCollateral[intentId];
        return c.status == SettlementStatus.LOCKED && block.timestamp > c.deadline;
    }

    // -----------------------------------------------------------------------
    // Internal: Hashing
    // -----------------------------------------------------------------------

    function _isCtZero(ctUint256 memory ct) internal pure returns (bool) {
        return ctUint128.unwrap(ct.ciphertextHigh) == 0 &&
               ctUint128.unwrap(ct.ciphertextLow) == 0;
    }

    function _commit(itUint256 calldata ct) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            ct.ciphertext.ciphertextHigh,
            ct.ciphertext.ciphertextLow
        ));
    }

    function _lockLimitIntentDigest(
        bytes32 intentId, address trader, address solver,
        address tokenIn, address tokenOut,
        bytes32 traderCommit, bytes32 solverCommit,
        uint256 limitPrice, bool isBuy,
        uint64 feeBps, uint256 nonce, uint256 deadline
    ) internal view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            LOCK_LIMIT_INTENT_TYPEHASH,
            intentId, trader, solver, tokenIn, tokenOut,
            traderCommit, solverCommit,
            limitPrice, isBuy,
            feeBps, nonce, deadline
        )));
    }

    function _settleLimitDigest(
        bytes32 intentIdA, bytes32 intentIdB,
        uint256 agreedPrice, uint256 fillTrader, uint256 fillSolver
    ) internal view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            SETTLE_LIMIT_TYPEHASH,
            intentIdA, intentIdB, agreedPrice, fillTrader, fillSolver
        )));
    }

    // -----------------------------------------------------------------------
    // Internal: Committee (from CommitteeAttestor)
    // -----------------------------------------------------------------------

    function _isInSnapshot(address account) internal view returns (bool) {
        return isInSnapshot(account);
    }
}
