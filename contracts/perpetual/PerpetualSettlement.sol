// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {IBridgeVerifier} from "../bridge/IBridgeVerifier.sol";

contract PerpetualSettlement is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    EIP712Upgradeable,
    ERC2771ContextUpgradeable
{
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant MAX_FEE_BPS = 1000;
    uint256 private constant MAX_LEVERAGE = 100;
    uint256 private constant MINIMUM_ACCOUNT_MARGIN = 1e18;
    uint256 private constant LIQUIDATION_FEE_BPS = 50;
    uint256 private constant LIQUIDATOR_REWARD_BPS = 50;
    uint256 private constant MAX_PARTIAL_LIQUIDATION_RATIO = 8000;
    uint256 private constant MIN_PARTIAL_LIQUIDATION_RATIO = 2000;
    uint256 private constant TARGET_HEALTH_AFTER_PARTIAL = 15_000;
    uint256 private constant HEALTH_PRECISION = 10_000;
    uint256 private constant MAX_PRICE_AGE = 1 hours;
    uint256 private constant MAX_PRICE_DEVIATION_BPS = 500;
    /// @dev VT-16: medianized mark price. The ORACLE_ROLE holder is the
    ///      aggregator that forwards a quorum-signed median; the contract
    ///      verifies M-of-N committee signatures via the L1
    ///      `RandomCommitteeVerifierV2` instead of trusting a bare number.
    uint256 private constant MAX_LIQUIDATION_CHALLENGE_WINDOW = 24 hours;
    uint256 private constant MAX_LIQUIDATOR_BOND_BPS = 2000; // 20%
    /// @dev Post-Pioneer, OmniTimelockController will hold DEFAULT_ADMIN_ROLE
    ///      and enforce upgrade delays centrally. No per-contract timelock needed.

    // -----------------------------------------------------------------------
    // Roles
    // -----------------------------------------------------------------------

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");
    bytes32 public constant INSURANCE_MANAGER_ROLE = keccak256("INSURANCE_MANAGER_ROLE");

    /// @notice Domain tag bound into every mark-price digest. The off-chain
    ///         aggregator reconstructs this hash to collect committee
    ///         signatures over `(market, price, round)`.
    bytes32 public constant ORACLE_PRICE_DOMAIN = keccak256(
        "OmniBazaar.Perps.OraclePrice.v1"
    );

    // -----------------------------------------------------------------------
    // EIP-712 Types
    // -----------------------------------------------------------------------

    bytes32 public constant OPEN_POSITION_TYPEHASH = keccak256(
        "OpenPosition(address trader,bytes32 market,uint8 side,uint256 size,uint256 entryPrice,uint256 leverage,uint256 deadline,uint256 nonce)"
    );

    bytes32 public constant CLOSE_POSITION_TYPEHASH = keccak256(
        "ClosePosition(address trader,bytes32 positionId,uint256 exitPrice,uint256 deadline,uint256 nonce)"
    );

    bytes32 public constant ADD_MARGIN_TYPEHASH = keccak256(
        "AddMargin(address trader,bytes32 positionId,uint256 amount,uint256 deadline,uint256 nonce)"
    );

    // -----------------------------------------------------------------------
    // Structs
    // -----------------------------------------------------------------------

    struct MarketConfig {
        string name;
        address token;
        uint256 maintenanceMarginBps;
        uint256 initialMarginBps;
        uint256 takerFeeBps;
        uint256 makerFeeBps;
        uint256 maxLeverage;
        uint256 maxPositionSize;
        bool active;
    }

    struct Account {
        uint256 totalCollateral;
        uint256 usedMargin;
        uint256 availableMargin;
        int256 unrealizedPnL;
        uint256 accountValue;
        uint256 maintenanceMarginRequired;
        uint256 healthFactor;
        uint256 totalNotional;
        uint256 positionCount;
        uint256 lastUpdated;
    }

    struct Position {
        bytes32 market;
        address trader;
        uint8 side;
        uint256 size;
        uint256 entryPrice;
        uint256 leverage;
        uint256 notionalValue;
        uint256 initialMargin;
        uint256 maintenanceMargin;
        int256 unrealizedPnL;
        uint256 openedAt;
        uint256 lastUpdated;
    }

    struct MarkPrice {
        uint256 price;
        uint256 timestamp;
        uint256 oracleRound;
    }

    struct InsuranceFundState {
        uint256 balance;
        uint256 totalContributions;
        uint256 totalPayouts;
        uint256 shortfallsCovered;
    }

    /// @dev VT-16: a liquidation is "provisional" for
    ///      `liquidationChallengeWindow` before it is applied. The snapshot
    ///      captures every value needed to (a) apply the liquidation later
    ///      and (b) challenge it — the mark price AND the oracle round it
    ///      came from, so a challenge can prove the committee equivocated on
    ///      that round.
    struct ProvisionalLiquidation {
        bytes32 positionId;
        address liquidator;
        bytes32 market;
        uint256 markPrice;
        uint256 markRound;
        uint256 bond;
        uint256 raisedAt;
        uint256 liquidatedSize;
        uint256 remainingSize;
        uint256 reward;
        uint256 insuranceFee;
        int256 realizedPnl;
        bool finalized;
        bool reversed;
    }

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    IERC20 public collateralToken;
    uint256 public tradingFeeBps;
    uint256 public liquidationFeeBps;
    uint256 public liquidatorRewardBps;
    uint256 public maintenanceMarginBps;
    uint256 public initialMarginBps;
    uint256 public maxLeverage;
    uint256 public minAccountMargin;
    bool public ossified;

    mapping(bytes32 => MarketConfig) public markets;
    mapping(bytes32 => bool) public marketExists;
    bytes32[] public marketList;

    mapping(address => Account) public accounts;
    mapping(bytes32 => Position) public positions;
    mapping(address => bytes32[]) public userPositions;
    mapping(address => uint256) public userNonces;

    mapping(bytes32 => MarkPrice) public markPrices;

    InsuranceFundState public insuranceFund;

    address public insuranceTreasury;
    uint256 public minPositionSize;
    uint256 public maxPriceAge;
    uint256 public maxPriceDeviationBps;
    mapping(bytes32 => uint256) private _lastPrice;

    /// @dev VT-16: committee verifier (L1 `RandomCommitteeVerifierV2`) whose
    ///      M-of-N `verify` gates every mark-price update and liquidation
    ///      challenge.
    address public committeeVerifier;
    /// @dev VT-16: how long a liquidation stays provisional (challengeable).
    uint256 public liquidationChallengeWindow;
    /// @dev VT-16: liquidator bond, in bps of the liquidation value (10%).
    uint256 public liquidatorBondBps;
    /// @dev VT-16: provisional liquidation records, keyed by positionId.
    mapping(bytes32 => ProvisionalLiquidation) public provisionalLiquidations;
    /// @dev VT-16: per-trader count of positions under provisional
    ///      liquidation — used to block trader-initiated moves (withdraw /
    ///      close / open / add-margin) while any of their positions is
    ///      being liquidated.
    mapping(address => uint256) private _liquidationLockCount;

    // (PendingUpgrade struct + pendingUpgrade state removed — OmniTimelockController
    //  handles upgrade delays centrally post-Pioneer.)

    uint256[39] private __gap;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event AccountCreated(address indexed trader);
    event MarginDeposited(address indexed trader, uint256 amount, uint256 newBalance);
    event MarginWithdrawn(address indexed trader, uint256 amount, uint256 newBalance);
    event PositionOpened(bytes32 indexed positionId, address indexed trader, bytes32 indexed market, uint8 side, uint256 size, uint256 entryPrice, uint256 leverage);
    event PositionClosed(bytes32 indexed positionId, address indexed trader, int256 realizedPnL, uint256 exitPrice);
    event PositionLiquidated(bytes32 indexed positionId, address indexed trader, address indexed liquidator, uint256 liquidatedSize, uint256 remainingSize, int256 realizedPnL);
    event MarkPriceSubmitted(bytes32 indexed market, uint256 price, uint256 round);
    event InsuranceContributed(uint256 amount, uint256 newBalance);
    event InsurancePayout(uint256 amount, uint256 newBalance);
    event InsuranceShortfall(bytes32 indexed positionId, uint256 shortfallAmount);
    event InsuranceWithdrawn(address indexed manager, uint256 amount, uint256 newBalance);
    event MarketConfigured(bytes32 indexed market, string name, address token);
    event Ossified();
    /// @notice A provisional liquidation was opened (VT-16).
    event LiquidationProvisional(bytes32 indexed positionId, address indexed liquidator, uint256 bond, uint256 raisedAt);
    /// @notice A provisional liquidation was applied after the window (VT-16).
    event LiquidationFinalized(bytes32 indexed positionId, address indexed liquidator);
    /// @notice A provisional liquidation was reversed by a successful challenge (VT-16).
    event LiquidationChallenged(bytes32 indexed positionId, address indexed challenger, uint256 slashedBond);
    // (UpgradeQueued/UpgradeCancelled events removed — OmniTimelockController
    //  handles upgrade scheduling centrally post-Pioneer.)

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error MarketNotActive(bytes32 market);
    error MarketAlreadyExists(bytes32 market);
    error MarketDoesNotExist(bytes32 market);
    error InsufficientMargin(uint256 required, uint256 available);
    error PositionNotFound(bytes32 positionId);
    error PositionNotLiquidatable(bytes32 positionId, uint256 healthFactor);
    error LeverageExceedsMax(uint256 leverage, uint256 max);
    error PositionSizeExceedsMax(uint256 size, uint256 max);
    error AccountNotFound(address trader);
    error InsufficientCollateral(uint256 required, uint256 available);
    error DeadlineExpired(uint256 deadline);
    error InvalidSignature();
    error NonceAlreadyUsed(uint256 nonce);
    error ContractIsOssified();
    error NotEnoughInsuranceFund(uint256 required, uint256 available);
    error PriceStale(bytes32 market, uint256 timestamp);
    error PriceZero(bytes32 market);
    error CannotLiquidateOwnPosition();
    error InvalidSide(uint8 side);
    error PriceDeviationExceedsMax(uint256 newPrice, uint256 lastPrice, uint256 maxDeviation);
    error PositionSizeTooSmall(uint256 size, uint256 minSize);
    error InsuranceTreasuryNotSet();
    error OracleProofInvalid(bytes32 market);
    error StaleOracleRound(uint256 provided, uint256 current);
    error LiquidationPending(bytes32 positionId);
    error LiquidationNotFound(bytes32 positionId);
    error LiquidationNotFinalizable(bytes32 positionId, uint256 raisedAt);
    error ChallengeWindowElapsed(bytes32 positionId);
    error ChallengeRejected(bytes32 positionId);
    error RoundMismatch(uint256 honestRound, uint256 markRound);
    error AccountLiquidationLocked(address trader);
    error InvalidCommitteeVerifier();
    // (UpgradeNotScheduled/UpgradeDelayNotElapsed errors removed — OmniTimelockController
    //  handles upgrade scheduling centrally post-Pioneer.)

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder_)
        ERC2771ContextUpgradeable(trustedForwarder_)
    {
        _disableInitializers();
    }

    // -----------------------------------------------------------------------
    // Initializer
    // -----------------------------------------------------------------------

    function initialize(
        address collateralToken_,
        address admin_,
        address insuranceTreasury_,
        uint256 tradingFeeBps_,
        uint256 maintenanceMarginBps_,
        uint256 initialMarginBps_,
        uint256 maxLeverage_
    ) external initializer {
        if (collateralToken_ == address(0)) revert ZeroAddress();
        if (admin_ == address(0)) revert ZeroAddress();
        if (insuranceTreasury_ == address(0)) revert ZeroAddress();
        if (tradingFeeBps_ > MAX_FEE_BPS) revert ZeroAmount();
        if (maintenanceMarginBps_ == 0 || maintenanceMarginBps_ >= initialMarginBps_) revert ZeroAmount();
        if (initialMarginBps_ == 0 || initialMarginBps_ > BPS_DENOMINATOR) revert ZeroAmount();
        if (maxLeverage_ == 0 || maxLeverage_ > MAX_LEVERAGE) revert ZeroAmount();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __EIP712_init("PerpetualSettlement", "1");

        collateralToken = IERC20(collateralToken_);
        tradingFeeBps = tradingFeeBps_;
        liquidationFeeBps = LIQUIDATION_FEE_BPS;
        liquidatorRewardBps = LIQUIDATOR_REWARD_BPS;
        maintenanceMarginBps = maintenanceMarginBps_;
        initialMarginBps = initialMarginBps_;
        maxLeverage = maxLeverage_;
        minAccountMargin = MINIMUM_ACCOUNT_MARGIN;
        insuranceTreasury = insuranceTreasury_;
        minPositionSize = 1e16;
        maxPriceAge = MAX_PRICE_AGE;
        maxPriceDeviationBps = MAX_PRICE_DEVIATION_BPS;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    /**
     * @notice VT-16 reinitializer: wire the medianized-oracle committee
     *         verifier and the liquidation-challenge parameters.
     * @dev Called once via `upgradeToAndCall(newImpl, reinitData)` when the
     *      VT-16 implementation is applied to the already-deployed proxy.
     *      New state is appended (never inserted), so the pre-existing
     *      storage layout is preserved.
     * @param committeeVerifier_ The L1 `RandomCommitteeVerifierV2` (M-of-N).
     * @param challengeWindow_ How long a liquidation stays provisional.
     * @param bondBps_ Liquidator bond, in bps of liquidation value.
     */
    function reinitializeVT16(
        address committeeVerifier_,
        uint256 challengeWindow_,
        uint256 bondBps_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) reinitializer(2) {
        if (committeeVerifier_ == address(0)) revert InvalidCommitteeVerifier();
        if (challengeWindow_ == 0 || challengeWindow_ > MAX_LIQUIDATION_CHALLENGE_WINDOW) {
            revert ZeroAmount();
        }
        if (bondBps_ == 0 || bondBps_ > MAX_LIQUIDATOR_BOND_BPS) revert ZeroAmount();
        committeeVerifier = committeeVerifier_;
        liquidationChallengeWindow = challengeWindow_;
        liquidatorBondBps = bondBps_;
    }

    // -----------------------------------------------------------------------
    // UUPS
    // -----------------------------------------------------------------------

    /**
     * @notice Authorize a UUPS implementation upgrade.
     * @dev During Pioneer Phase, DEFAULT_ADMIN_ROLE (deployer) can upgrade
     *      immediately. Post-Pioneer, OmniTimelockController will hold
     *      DEFAULT_ADMIN_ROLE and enforce delays centrally — no per-contract
     *      scheduling machinery is needed.
     */
    function _authorizeUpgrade(address /* newImplementation */)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (ossified) revert ContractIsOssified();
    }

    function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) {
        ossified = true;
        emit Ossified();
    }

    // -----------------------------------------------------------------------
    // ERC-2771
    // -----------------------------------------------------------------------

    function _msgSender()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    function _contextSuffixLength()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }

    // -----------------------------------------------------------------------
    // Market Management (Admin)
    // -----------------------------------------------------------------------

    function configureMarket(
        bytes32 marketId,
        string calldata name,
        address token,
        uint256 maintenanceMarginBps_,
        uint256 initialMarginBps_,
        uint256 takerFeeBps_,
        uint256 makerFeeBps_,
        uint256 maxLeverage_,
        uint256 maxPositionSize_
    ) external onlyRole(ADMIN_ROLE) {
        if (marketExists[marketId]) revert MarketAlreadyExists(marketId);
        if (token == address(0)) revert ZeroAddress();
        if (maintenanceMarginBps_ == 0 || maintenanceMarginBps_ >= initialMarginBps_) revert ZeroAmount();
        if (initialMarginBps_ == 0 || initialMarginBps_ > BPS_DENOMINATOR) revert ZeroAmount();
        if (maxLeverage_ == 0 || maxLeverage_ > MAX_LEVERAGE) revert ZeroAmount();

        markets[marketId] = MarketConfig({
            name: name,
            token: token,
            maintenanceMarginBps: maintenanceMarginBps_,
            initialMarginBps: initialMarginBps_,
            takerFeeBps: takerFeeBps_,
            makerFeeBps: makerFeeBps_,
            maxLeverage: maxLeverage_,
            maxPositionSize: maxPositionSize_,
            active: true
        });
        marketExists[marketId] = true;
        marketList.push(marketId);

        emit MarketConfigured(marketId, name, token);
    }

    function deactivateMarket(bytes32 marketId) external onlyRole(ADMIN_ROLE) {
        if (!marketExists[marketId]) revert MarketDoesNotExist(marketId);
        markets[marketId].active = false;
    }

    function activateMarket(bytes32 marketId) external onlyRole(ADMIN_ROLE) {
        if (!marketExists[marketId]) revert MarketDoesNotExist(marketId);
        markets[marketId].active = true;
    }

    function setTradingFee(uint256 feeBps) external onlyRole(ADMIN_ROLE) {
        if (feeBps > MAX_FEE_BPS) revert ZeroAmount();
        tradingFeeBps = feeBps;
    }

    function setLiquidationParams(uint256 feeBps, uint256 rewardBps) external onlyRole(ADMIN_ROLE) {
        if (feeBps > MAX_FEE_BPS || rewardBps > MAX_FEE_BPS) revert ZeroAmount();
        liquidationFeeBps = feeBps;
        liquidatorRewardBps = rewardBps;
    }

    /**
     * @notice Set the liquidation-challenge window + bond (VT-16).
     * @dev Admin (Pioneer deployer-direct). Bounded by the VT-16 constants.
     */
    function setLiquidationChallengeParams(
        uint256 challengeWindow_,
        uint256 bondBps_
    ) external onlyRole(ADMIN_ROLE) {
        if (challengeWindow_ == 0 || challengeWindow_ > MAX_LIQUIDATION_CHALLENGE_WINDOW) {
            revert ZeroAmount();
        }
        if (bondBps_ == 0 || bondBps_ > MAX_LIQUIDATOR_BOND_BPS) revert ZeroAmount();
        liquidationChallengeWindow = challengeWindow_;
        liquidatorBondBps = bondBps_;
    }

    // -----------------------------------------------------------------------
    // Oracle (ORACLE_ROLE)
    // -----------------------------------------------------------------------

    /**
     * @notice Submit a quorum-signed median mark price (VT-16).
     * @dev The ORACLE_ROLE holder is the *aggregator*: it computes the
     *      median of the gateway validator observations off-chain, then
     *      forwards it together with an M-of-N committee proof. The contract
     *      verifies the proof via {committeeVerifier} instead of trusting a
     *      bare number, so no single key can move the mark price.
     *
     *      The signed digest is `keccak256(abi.encode(ORACLE_PRICE_DOMAIN,
     *      address(this), market, price, round))`. `round` MUST be strictly
     *      greater than the last accepted round (replay protection); the
     *      off-chain aggregator reads the current round via {getMarkPrice}
     *      and pins the digest via the verifier's `requestCommitteeSeed`
     *      before collecting signatures.
     *
     *      The first accepted price for a market must also be a valid median
     *      — there is no single-seeder shortcut, closing the initial-price
     *      anchor gap.
     * @param market The market id.
     * @param price The median (or consensus) price.
     * @param round Monotonic oracle round (must exceed the current round).
     * @param proof Committee proof over the digest above.
     */
    function submitMarkPrice(
        bytes32 market,
        uint256 price,
        uint256 round,
        bytes calldata proof
    ) external onlyRole(ORACLE_ROLE) {
        if (!marketExists[market]) revert MarketDoesNotExist(market);
        if (price == 0) revert PriceZero(market);
        if (committeeVerifier == address(0)) revert InvalidCommitteeVerifier();

        MarkPrice storage mp = markPrices[market];
        if (round <= mp.oracleRound) revert StaleOracleRound(round, mp.oracleRound);

        bytes32 digest = _oracleDigest(market, price, round);
        (bool valid, ) = IBridgeVerifier(committeeVerifier).verify(digest, proof);
        if (!valid) revert OracleProofInvalid(market);

        uint256 lastPrice = _lastPrice[market];
        if (lastPrice > 0) {
            uint256 deviation = price > lastPrice
                ? ((price - lastPrice) * BPS_DENOMINATOR) / lastPrice
                : ((lastPrice - price) * BPS_DENOMINATOR) / lastPrice;
            if (deviation > maxPriceDeviationBps) {
                revert PriceDeviationExceedsMax(price, lastPrice, maxPriceDeviationBps);
            }
        }

        mp.price = price;
        mp.timestamp = block.timestamp;
        mp.oracleRound = round;
        _lastPrice[market] = price;

        emit MarkPriceSubmitted(market, price, round);
    }

    /**
     * @notice Reconstruct the signed mark-price digest (VT-16).
     * @dev The digest is `keccak256(abi.encode(ORACLE_PRICE_DOMAIN,
     *      address(this), market, price, round))`.
     */
    function _oracleDigest(bytes32 market, uint256 price, uint256 round)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(ORACLE_PRICE_DOMAIN, address(this), market, price, round)
        );
    }

    function getMarkPrice(bytes32 market) external view returns (uint256 price, uint256 timestamp, uint256 round) {
        MarkPrice storage mp = markPrices[market];
        return (mp.price, mp.timestamp, mp.oracleRound);
    }

    // -----------------------------------------------------------------------
    // Account Management
    // -----------------------------------------------------------------------

    function depositMargin(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        collateralToken.safeTransferFrom(_msgSender(), address(this), amount);

        Account storage account = accounts[_msgSender()];
        if (account.lastUpdated == 0) {
            account.lastUpdated = block.timestamp;
            emit AccountCreated(_msgSender());
        }

        account.totalCollateral += amount;
        _recalculateAccount(_msgSender());

        emit MarginDeposited(_msgSender(), amount, account.totalCollateral);
    }

    function withdrawMargin(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        Account storage account = accounts[_msgSender()];
        if (account.lastUpdated == 0) revert AccountNotFound(_msgSender());
        if (_liquidationLockCount[_msgSender()] > 0) revert AccountLiquidationLocked(_msgSender());

        uint256 minRequired = _calculateMinimumCollateral(_msgSender());
        if (account.totalCollateral < amount) revert InsufficientCollateral(amount, account.totalCollateral);

        uint256 remainingCollateral = account.totalCollateral - amount;
        if (account.positionCount > 0 && remainingCollateral < minRequired) {
            revert InsufficientCollateral(minRequired, remainingCollateral);
        }

        account.totalCollateral = remainingCollateral;
        _recalculateAccount(_msgSender());

        collateralToken.safeTransfer(_msgSender(), amount);

        emit MarginWithdrawn(_msgSender(), amount, account.totalCollateral);
    }

    // -----------------------------------------------------------------------
    // Position Management
    // -----------------------------------------------------------------------

    function openPosition(
        bytes32 market,
        uint8 side,
        uint256 size,
        uint256 entryPrice,
        uint256 leverage,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        address trader = _msgSender();

        _useNonce(trader, nonce);
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);

        bytes32 structHash = keccak256(
            abi.encode(
                OPEN_POSITION_TYPEHASH,
                trader,
                market,
                side,
                size,
                entryPrice,
                leverage,
                deadline,
                nonce
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        if (signer != trader) revert InvalidSignature();

        _openPosition(trader, market, side, size, entryPrice, leverage);
    }

    function closePosition(
        bytes32 positionId,
        uint256 exitPrice,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        address trader = _msgSender();

        _useNonce(trader, nonce);
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);

        bytes32 structHash = keccak256(
            abi.encode(
                CLOSE_POSITION_TYPEHASH,
                trader,
                positionId,
                exitPrice,
                deadline,
                nonce
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        if (signer != trader) revert InvalidSignature();

        _closePosition(trader, positionId, exitPrice);
    }

    function addMarginToPosition(
        bytes32 positionId,
        uint256 amount,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        address trader = _msgSender();

        _useNonce(trader, nonce);
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);

        bytes32 structHash = keccak256(
            abi.encode(
                ADD_MARGIN_TYPEHASH,
                trader,
                positionId,
                amount,
                deadline,
                nonce
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        if (signer != trader) revert InvalidSignature();

        Position storage position = positions[positionId];
        if (position.trader != trader) revert PositionNotFound(positionId);
        if (_liquidationLockCount[trader] > 0) revert AccountLiquidationLocked(trader);

        collateralToken.safeTransferFrom(trader, address(this), amount);

        Account storage account = accounts[trader];
        account.totalCollateral += amount;
        _recalculateAccount(trader);

        emit MarginDeposited(trader, amount, account.totalCollateral);
    }

    // -----------------------------------------------------------------------
    // Liquidation (LIQUIDATOR_ROLE)
    // -----------------------------------------------------------------------
    //
    // VT-16 security model: the M-of-N committee proof on {submitMarkPrice}
    // means no single key can move the mark price. The remaining trust
    // assumption is OFF-CHAIN policy: the gateway validators must sign the
    // median of their OWN observations (not the aggregator's number) and must
    // be willing to re-sign a round's true median when a challenger requests
    // it — otherwise {challengeLiquidation} has no competing signature to
    // verify against. The oracle signers' own OmniCore stake is slashable for
    // signing an outlier (equivocation) via the L1 AttestationFraudHandler
    // (VT-09). A liquidator's bond is slashed whenever the mark price is
    // proven an outlier, even if the liquidator itself was not at fault — the
    // bond is the liquidator's skin-in-the-game against using a bad price.

    /**
     * @notice Open a PROVISIONAL liquidation (VT-16).
     * @dev The liquidation is not applied yet — it stays challengeable for
     *      {liquidationChallengeWindow}. The liquidator posts a bond of
     *      `liquidatorBondBps` of the liquidation value, escrowed here and
     *      returned on {finalizeLiquidation} or slashed on an upheld
     *      {challengeLiquidation}. While provisional, the position (and the
     *      trader's account) is locked against trader-initiated moves.
     * @param positionId The position to liquidate.
     */
    function liquidatePosition(bytes32 positionId) external nonReentrant whenNotPaused onlyRole(LIQUIDATOR_ROLE) {
        if (_liquidationActive(positionId)) revert LiquidationPending(positionId);

        Position storage position = positions[positionId];
        if (position.size == 0) revert PositionNotFound(positionId);
        if (position.trader == _msgSender()) revert CannotLiquidateOwnPosition();

        Account storage account = accounts[position.trader];
        if (account.lastUpdated == 0) revert AccountNotFound(position.trader);

        _recalculateAccount(position.trader);

        if (account.healthFactor >= HEALTH_PRECISION) {
            revert PositionNotLiquidatable(positionId, account.healthFactor);
        }

        MarkPrice storage mp = markPrices[position.market];
        if (mp.price == 0) revert PriceZero(position.market);
        if (block.timestamp > mp.timestamp + maxPriceAge) revert PriceStale(position.market, mp.timestamp);

        uint256 markPrice = mp.price;
        uint256 markRound = mp.oracleRound;

        bool usePartial = position.size >= 1e18;
        uint256 liquidatedSize;
        uint256 remainingSize;

        if (usePartial) {
            uint256 ratio = _calculatePartialLiquidationRatio(account.healthFactor);
            liquidatedSize = (position.size * ratio) / BPS_DENOMINATOR;
            if (liquidatedSize == 0) liquidatedSize = position.size / 5;
            if (liquidatedSize > position.size) liquidatedSize = position.size;
            remainingSize = position.size - liquidatedSize;
        } else {
            liquidatedSize = position.size;
            remainingSize = 0;
        }

        int256 realizedPnl = _calculatePnL(
            position.side,
            liquidatedSize,
            position.entryPrice,
            markPrice
        );

        uint256 positionValue = (liquidatedSize * markPrice) / 1e18;
        uint256 liquidatorReward = (positionValue * liquidatorRewardBps) / BPS_DENOMINATOR;
        uint256 insuranceFee = (positionValue * liquidationFeeBps) / BPS_DENOMINATOR;
        uint256 bond = (positionValue * liquidatorBondBps) / BPS_DENOMINATOR;

        // Effects before interactions: record the provisional liquidation and
        // lock the account, then escrow the bond.
        ProvisionalLiquidation storage liq = provisionalLiquidations[positionId];
        liq.positionId = positionId;
        liq.liquidator = _msgSender();
        liq.market = position.market;
        liq.markPrice = markPrice;
        liq.markRound = markRound;
        liq.bond = bond;
        liq.raisedAt = block.timestamp;
        liq.liquidatedSize = liquidatedSize;
        liq.remainingSize = remainingSize;
        liq.reward = liquidatorReward;
        liq.insuranceFee = insuranceFee;
        liq.realizedPnl = realizedPnl;
        liq.finalized = false;
        liq.reversed = false;

        _liquidationLockCount[position.trader]++;

        if (bond > 0) {
            collateralToken.safeTransferFrom(_msgSender(), address(this), bond);
        }

        emit LiquidationProvisional(positionId, _msgSender(), bond, block.timestamp);
    }

    /**
     * @notice Apply an unchallenged provisional liquidation (VT-16).
     * @dev Permissionless. Callable only after {liquidationChallengeWindow}
     *      has elapsed since {liquidatePosition}. Applies the snapshot
     *      (position reduction/removal, collateral adjustment, insurance fee,
     *      reward) and returns the liquidator's bond.
     * @param positionId The position to finalize.
     */
    function finalizeLiquidation(bytes32 positionId) external nonReentrant whenNotPaused {
        ProvisionalLiquidation storage liq = provisionalLiquidations[positionId];
        if (liq.raisedAt == 0 || liq.finalized || liq.reversed) {
            revert LiquidationNotFound(positionId);
        }
        if (block.timestamp < liq.raisedAt + liquidationChallengeWindow) {
            revert LiquidationNotFinalizable(positionId, liq.raisedAt);
        }

        address trader = positions[positionId].trader;
        address liquidator = liq.liquidator;
        uint256 bond = liq.bond;
        uint256 liquidatedSize = liq.liquidatedSize;
        uint256 remainingSize = liq.remainingSize;
        int256 realizedPnl = liq.realizedPnl;

        liq.finalized = true;
        _liquidationLockCount[trader]--;

        _applyLiquidation(positionId, liq);

        if (bond > 0) {
            collateralToken.safeTransfer(liquidator, bond);
        }

        emit PositionLiquidated(positionId, trader, liquidator, liquidatedSize, remainingSize, realizedPnl);
        emit LiquidationFinalized(positionId, liquidator);
    }

    /**
     * @notice Challenge a provisional liquidation with proof that the mark
     *         price used was an outlier (VT-16).
     * @dev Permissionless, within the challenge window. The challenger
     *      submits a valid committee proof over a competing price for the
     *      SAME oracle round the liquidation used. If that honest price
     *      deviates from the liquidation's mark price by more than
     *      {maxPriceDeviationBps}, the committee equivocated on that round —
     *      the liquidation is reversed and the liquidator's bond is slashed
     *      to the challenger. A challenge that fails the deviation test is
     *      rejected (no slashing).
     * @param positionId The provisional liquidation to challenge.
     * @param honestPrice The honest median price for the same round.
     * @param honestRound The oracle round (must equal the liquidation's mark round).
     * @param proof Committee proof over `(market, honestPrice, honestRound)`.
     */
    function challengeLiquidation(
        bytes32 positionId,
        uint256 honestPrice,
        uint256 honestRound,
        bytes calldata proof
    ) external nonReentrant whenNotPaused {
        ProvisionalLiquidation storage liq = provisionalLiquidations[positionId];
        if (liq.raisedAt == 0 || liq.finalized || liq.reversed) {
            revert LiquidationNotFound(positionId);
        }
        if (block.timestamp >= liq.raisedAt + liquidationChallengeWindow) {
            revert ChallengeWindowElapsed(positionId);
        }
        if (honestRound != liq.markRound) revert RoundMismatch(honestRound, liq.markRound);

        bytes32 digest = _oracleDigest(liq.market, honestPrice, honestRound);
        (bool valid, ) = IBridgeVerifier(committeeVerifier).verify(digest, proof);
        if (!valid) revert OracleProofInvalid(liq.market);

        uint256 markPrice = liq.markPrice;
        uint256 deviation = honestPrice > markPrice
            ? ((honestPrice - markPrice) * BPS_DENOMINATOR) / markPrice
            : ((markPrice - honestPrice) * BPS_DENOMINATOR) / markPrice;
        // Strict `<` (not `<=`): a deviation of exactly `maxPriceDeviationBps`
        // is still an outlier and must be challengeable, otherwise a mark
        // pushed to exactly the breaker bound is unreversible.
        if (deviation < maxPriceDeviationBps) revert ChallengeRejected(positionId);

        address trader = positions[positionId].trader;
        uint256 bond = liq.bond;

        liq.reversed = true;
        _liquidationLockCount[trader]--;

        if (bond > 0) {
            collateralToken.safeTransfer(_msgSender(), bond);
        }

        emit LiquidationChallenged(positionId, _msgSender(), bond);
    }

    /**
     * @notice Whether a position has an active provisional liquidation.
     */
    function _liquidationActive(bytes32 positionId) internal view returns (bool) {
        ProvisionalLiquidation storage liq = provisionalLiquidations[positionId];
        return liq.raisedAt != 0 && !liq.finalized && !liq.reversed;
    }

    /**
     * @notice Apply a finalized liquidation snapshot (VT-16).
     * @dev Mirrors the pre-VT-16 {liquidatePosition} mutation, driven by the
     *      stored snapshot values. Shortfall is recomputed against the
     *      CURRENT collateral (the account may have received deposits during
     *      the window), but the reward/insurance-fee/realized-PnL figures are
     *      the snapshot taken at liquidation time.
     */
    function _applyLiquidation(bytes32 positionId, ProvisionalLiquidation storage liq) internal {
        Position storage position = positions[positionId];
        Account storage account = accounts[position.trader];

        uint256 remainingSize = liq.remainingSize;
        uint256 markPrice = liq.markPrice;

        if (remainingSize > 0) {
            uint256 reductionRatio = (remainingSize * BPS_DENOMINATOR) / position.size;
            position.size = remainingSize;
            position.notionalValue = (position.notionalValue * reductionRatio) / BPS_DENOMINATOR;
            position.initialMargin = (position.initialMargin * reductionRatio) / BPS_DENOMINATOR;
            position.maintenanceMargin = (position.maintenanceMargin * reductionRatio) / BPS_DENOMINATOR;
            position.lastUpdated = block.timestamp;
            position.unrealizedPnL = _calculatePnL(
                position.side,
                remainingSize,
                position.entryPrice,
                markPrice
            );
        } else {
            _removePosition(positionId, position.trader);
        }

        // RT-01 (VT-16.1): debit the liquidation insurance fee from the trader's
        // collateral so the `insuranceFund.balance +=` credit below is backed by
        // real tokens. Pre-fix the fee was credited without a debit (phantom
        // credit), letting the fund's books outgrow its real backing over time.
        int256 newCollateral =
            int256(account.totalCollateral) + liq.realizedPnl -
            int256(liq.insuranceFee);

        if (newCollateral < 0) {
            _coverShortfall(positionId, uint256(-newCollateral));
            account.totalCollateral = 0;
        } else {
            account.totalCollateral = uint256(newCollateral);
        }

        insuranceFund.balance += liq.insuranceFee;
        insuranceFund.totalContributions += liq.insuranceFee;

        // RT-02 (VT-16.1): the liquidator reward is paid ONLY from the trader's
        // remaining collateral. Pre-fix a zero-equity position fell through to
        // the insurance fund, letting a LIQUIDATOR_ROLE holder repeatedly
        // extract the value-proportional reward from the backstop.
        uint256 liquidatorReward = liq.reward;
        address liquidator = liq.liquidator;
        if (liquidatorReward > 0 && account.totalCollateral >= liquidatorReward) {
            account.totalCollateral -= liquidatorReward;
            collateralToken.safeTransfer(liquidator, liquidatorReward);
        }

        _recalculateAccount(position.trader);
    }

    // -----------------------------------------------------------------------
    // Insurance Fund
    // -----------------------------------------------------------------------

    function depositInsurance(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        collateralToken.safeTransferFrom(_msgSender(), address(this), amount);
        insuranceFund.balance += amount;
        insuranceFund.totalContributions += amount;
        emit InsuranceContributed(amount, insuranceFund.balance);
    }

    function withdrawInsurance(uint256 amount) external nonReentrant onlyRole(INSURANCE_MANAGER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (insuranceTreasury == address(0)) revert InsuranceTreasuryNotSet();
        if (amount > insuranceFund.balance) revert NotEnoughInsuranceFund(amount, insuranceFund.balance);
        insuranceFund.balance -= amount;
        collateralToken.safeTransfer(insuranceTreasury, amount);
        emit InsuranceWithdrawn(_msgSender(), amount, insuranceFund.balance);
    }

    // -----------------------------------------------------------------------
    // Pause
    // -----------------------------------------------------------------------

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function getAccount(address trader) external view returns (Account memory) {
        return accounts[trader];
    }

    function getPosition(bytes32 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    function getUserPositions(address trader) external view returns (bytes32[] memory) {
        return userPositions[trader];
    }

    function getMarketCount() external view returns (uint256) {
        return marketList.length;
    }

    function getInsuranceFund() external view returns (InsuranceFundState memory) {
        return insuranceFund;
    }

    function isLiquidatable(address trader) external view returns (bool) {
        Account storage account = accounts[trader];
        if (account.lastUpdated == 0) return false;
        return account.healthFactor < HEALTH_PRECISION;
    }

    function getLiquidatableAccounts() external view returns (address[] memory) {
        bytes32[] storage userPos = userPositions[_msgSender()];
        uint256 maxAccounts = userPos.length;
        address[] memory liquidatable = new address[](maxAccounts);
        uint256 found;

        for (uint256 i = 0; i < maxAccounts; i++) {
            bytes32 posId = userPos[i];
            Position storage pos = positions[posId];
            if (pos.size == 0) continue;
            Account storage acc = accounts[pos.trader];
            if (acc.lastUpdated > 0 && acc.healthFactor < HEALTH_PRECISION) {
                liquidatable[found] = pos.trader;
                found++;
            }
        }

        assembly {
            mstore(liquidatable, found)
        }
        return liquidatable;
    }

    // -----------------------------------------------------------------------
    // Internal: Position Management
    // -----------------------------------------------------------------------

    function _openPosition(
        address trader,
        bytes32 market,
        uint8 side,
        uint256 size,
        uint256 entryPrice,
        uint256 leverage
    ) internal {
        if (_liquidationLockCount[trader] > 0) revert AccountLiquidationLocked(trader);
        if (!marketExists[market]) revert MarketDoesNotExist(market);
        MarketConfig storage marketCfg = markets[market];
        if (!marketCfg.active) revert MarketNotActive(market);
        // VT-16: a position can only open once a valid committee-signed median
        // exists for the market — no single seeder, no first-price anchor gap.
        if (markPrices[market].price == 0) revert PriceZero(market);
        if (side != 0 && side != 1) revert InvalidSide(side);
        if (size == 0) revert ZeroAmount();
        if (size < minPositionSize) revert PositionSizeTooSmall(size, minPositionSize);
        if (entryPrice == 0) revert ZeroAmount();
        if (leverage == 0 || leverage > marketCfg.maxLeverage) revert LeverageExceedsMax(leverage, marketCfg.maxLeverage);
        if (size > marketCfg.maxPositionSize) revert PositionSizeExceedsMax(size, marketCfg.maxPositionSize);

        Account storage account = accounts[trader];
        if (account.lastUpdated == 0) {
            account.lastUpdated = block.timestamp;
            emit AccountCreated(trader);
        }

        uint256 notionalValue = (size * entryPrice) / 1e18;
        uint256 leverageMargin = notionalValue / leverage;
        uint256 floorMargin = (notionalValue * marketCfg.initialMarginBps) / BPS_DENOMINATOR;
        uint256 initialMargin = leverageMargin > floorMargin ? leverageMargin : floorMargin;
        uint256 maintenanceMargin = (notionalValue * marketCfg.maintenanceMarginBps) / BPS_DENOMINATOR;

        if (account.totalCollateral < initialMargin) {
            revert InsufficientMargin(initialMargin, account.totalCollateral);
        }

        bytes32 positionId = keccak256(abi.encode(trader, market, side, block.timestamp, block.number, userNonces[trader]));

        positions[positionId] = Position({
            market: market,
            trader: trader,
            side: side,
            size: size,
            entryPrice: entryPrice,
            leverage: leverage,
            notionalValue: notionalValue,
            initialMargin: initialMargin,
            maintenanceMargin: maintenanceMargin,
            unrealizedPnL: 0,
            openedAt: block.timestamp,
            lastUpdated: block.timestamp
        });

        userPositions[trader].push(positionId);

        account.usedMargin += initialMargin;
        account.maintenanceMarginRequired += maintenanceMargin;
        account.totalNotional += notionalValue;
        account.positionCount++;

        _recalculateAccount(trader);

        emit PositionOpened(positionId, trader, market, side, size, entryPrice, leverage);
    }

    function _closePosition(address trader, bytes32 positionId, uint256 exitPrice) internal {
        if (_liquidationLockCount[trader] > 0) revert AccountLiquidationLocked(trader);
        Position storage position = positions[positionId];
        if (position.size == 0) revert PositionNotFound(positionId);
        if (position.trader != trader) revert PositionNotFound(positionId);
        if (exitPrice == 0) revert ZeroAmount();

        int256 realizedPnl = _calculatePnL(position.side, position.size, position.entryPrice, exitPrice);

        Account storage account = accounts[trader];
        if (realizedPnl >= 0) {
            account.totalCollateral += uint256(realizedPnl);
        } else {
            uint256 loss = uint256(-realizedPnl);
            if (loss > account.totalCollateral) {
                account.totalCollateral = 0;
            } else {
                account.totalCollateral -= loss;
            }
        }

        _removePosition(positionId, trader);
        _recalculateAccount(trader);

        emit PositionClosed(positionId, trader, realizedPnl, exitPrice);
    }

    function _removePosition(bytes32 positionId, address trader) internal {
        Position storage position = positions[positionId];
        Account storage account = accounts[trader];

        account.usedMargin -= position.initialMargin;
        account.maintenanceMarginRequired -= position.maintenanceMargin;
        account.totalNotional -= position.notionalValue;
        if (account.positionCount > 0) {
            account.positionCount--;
        }

        delete positions[positionId];

        bytes32[] storage userPos = userPositions[trader];
        for (uint256 i = 0; i < userPos.length; i++) {
            if (userPos[i] == positionId) {
                userPos[i] = userPos[userPos.length - 1];
                userPos.pop();
                break;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Internal: Accounting
    // -----------------------------------------------------------------------

    function _recalculateAccount(address trader) internal {
        Account storage account = accounts[trader];
        if (account.lastUpdated == 0) return;

        int256 totalUnrealizedPnL;
        uint256 totalUsedMargin;
        uint256 totalMaintenanceMargin;
        uint256 totalNotional;

        bytes32[] storage userPos = userPositions[trader];
        for (uint256 i = 0; i < userPos.length; i++) {
            Position storage pos = positions[userPos[i]];
            if (pos.size == 0) continue;

            MarkPrice storage mp = markPrices[pos.market];
            uint256 markPrice = mp.price > 0 ? mp.price : pos.entryPrice;

            int256 pnl = _calculatePnL(pos.side, pos.size, pos.entryPrice, markPrice);
            pos.unrealizedPnL = pnl;
            totalUnrealizedPnL += pnl;
            totalUsedMargin += pos.initialMargin;
            totalMaintenanceMargin += pos.maintenanceMargin;
            totalNotional += pos.notionalValue;
        }

        account.unrealizedPnL = totalUnrealizedPnL;
        account.usedMargin = totalUsedMargin;
        account.maintenanceMarginRequired = totalMaintenanceMargin;
        account.totalNotional = totalNotional;

        int256 accountValueInt = int256(account.totalCollateral) + totalUnrealizedPnL;
        account.accountValue = accountValueInt >= 0 ? uint256(accountValueInt) : 0;

        if (totalMaintenanceMargin > 0) {
            account.healthFactor = (account.accountValue * HEALTH_PRECISION) / totalMaintenanceMargin;
        } else {
            account.healthFactor = type(uint256).max;
        }

        account.availableMargin = account.accountValue > totalUsedMargin
            ? account.accountValue - totalUsedMargin
            : 0;

        account.lastUpdated = block.timestamp;
    }

    function _calculatePnL(uint8 side, uint256 size, uint256 entryPrice, uint256 exitPrice)
        internal
        pure
        returns (int256)
    {
        if (exitPrice == entryPrice) return 0;

        if (side == 0) {
            return (int256(size) * (int256(exitPrice) - int256(entryPrice))) / 1e18;
        } else {
            return (int256(size) * (int256(entryPrice) - int256(exitPrice))) / 1e18;
        }
    }

    function _calculateMinimumCollateral(address trader) internal view returns (uint256) {
        Account storage account = accounts[trader];
        if (account.maintenanceMarginRequired == 0) return 0;

        uint256 minCollateral = account.maintenanceMarginRequired;

        if (account.unrealizedPnL < 0) {
            minCollateral += uint256(-account.unrealizedPnL);
        }

        return minCollateral;
    }

    function _calculatePartialLiquidationRatio(uint256 healthFactor) internal pure returns (uint256) {
        uint256 ratio = BPS_DENOMINATOR - ((healthFactor * BPS_DENOMINATOR) / TARGET_HEALTH_AFTER_PARTIAL);

        if (ratio < MIN_PARTIAL_LIQUIDATION_RATIO) return MIN_PARTIAL_LIQUIDATION_RATIO;
        if (ratio > MAX_PARTIAL_LIQUIDATION_RATIO) return MAX_PARTIAL_LIQUIDATION_RATIO;
        return ratio;
    }

    // -----------------------------------------------------------------------
    // Internal: Insurance
    // -----------------------------------------------------------------------

    function _coverShortfall(bytes32 positionId, uint256 shortfall) internal {
        if (insuranceFund.balance >= shortfall) {
            insuranceFund.balance -= shortfall;
            insuranceFund.totalPayouts += shortfall;
            insuranceFund.shortfallsCovered++;
            emit InsurancePayout(shortfall, insuranceFund.balance);
        } else {
            insuranceFund.totalPayouts += insuranceFund.balance;
            insuranceFund.shortfallsCovered++;
            emit InsurancePayout(insuranceFund.balance, 0);
            insuranceFund.balance = 0;
            emit InsuranceShortfall(positionId, shortfall);
        }
    }

    // -----------------------------------------------------------------------
    // Internal: Nonce
    // -----------------------------------------------------------------------

    function _useNonce(address trader, uint256 nonce) internal {
        if (nonce <= userNonces[trader]) revert NonceAlreadyUsed(nonce);
        userNonces[trader] = nonce;
    }
}
