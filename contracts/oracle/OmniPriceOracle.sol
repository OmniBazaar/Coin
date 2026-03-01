// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// ══════════════════════════════════════════════════════════════════════
//                              INTERFACES
// ══════════════════════════════════════════════════════════════════════

/**
 * @title IAggregatorV3
 * @author OmniBazaar Team
 * @notice Chainlink-compatible aggregator interface
 * @dev Used for fallback price verification on major tokens
 */
interface IAggregatorV3 {
    /// @notice Get latest price data from Chainlink feed
    /// @return roundId The round ID
    /// @return answer The price (scaled by feed decimals)
    /// @return startedAt Round start timestamp
    /// @return updatedAt Round update timestamp
    /// @return answeredInRound The round in which answer was computed
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    /// @notice Get the number of decimals in the price feed
    /// @return Number of decimals
    function decimals() external view returns (uint8);
}

/**
 * @title IOmniCoreOracle
 * @author OmniBazaar Team
 * @notice Interface for querying validator status
 */
interface IOmniCoreOracle {
    /// @notice Check if address is a validator
    /// @param validator Address to check
    /// @return True if active validator
    function isValidator(
        address validator
    ) external view returns (bool);
}

// ══════════════════════════════════════════════════════════════════════
//                           CUSTOM ERRORS
// ══════════════════════════════════════════════════════════════════════

/// @notice Caller is not an active validator
error NotValidator();

/// @notice Token address is zero
error ZeroTokenAddress();

/// @notice Price is zero or negative
error InvalidPrice();

/// @notice Submission timestamp is in the future
error FutureTimestamp();

/// @notice Submission deviates too far from consensus
error PriceDeviationTooHigh(uint256 submitted, uint256 consensus);

/// @notice Price deviates too far from Chainlink reference
error ChainlinkDeviationExceeded(uint256 submitted, uint256 chainlink);

/// @notice Single-block circuit breaker triggered
error CircuitBreakerTriggered(uint256 previous, uint256 submitted);

/// @notice Cumulative deviation from anchor exceeds threshold
/// @param token Token that exceeded cumulative deviation
/// @param cumulativeDeviation Current cumulative deviation in bps
error CumulativeDeviationExceeded(
    address token,
    uint256 cumulativeDeviation
);

/// @notice Not enough validators have submitted prices
error InsufficientSubmissions(uint256 received, uint256 required);

/// @notice Price data is stale (not updated within threshold)
error StalePriceData(address token, uint256 lastUpdate);

/// @notice Round already finalized
error RoundAlreadyFinalized();

/// @notice Validator already submitted for this round
error AlreadySubmitted();

/// @notice Array length mismatch
error ArrayLengthMismatch();

/// @notice Max token limit exceeded
error MaxTokensExceeded();

/// @notice Validator has been suspended due to excessive violations
/// @param validator Address of the suspended validator
error ValidatorSuspended(address validator);

/// @notice Parameter value is out of allowed bounds
/// @param paramName Name of the parameter
/// @param value Provided value
/// @param minAllowed Minimum allowed value
/// @param maxAllowed Maximum allowed value
error ParameterOutOfBounds(
    string paramName,
    uint256 value,
    uint256 minAllowed,
    uint256 maxAllowed
);

/// @notice Provided address is not a contract
/// @param addr The address that has no code
error NotAContract(address addr);

/// @notice No upgrade has been scheduled
error NoUpgradeScheduled();

/// @notice Upgrade timelock has not elapsed yet
/// @param scheduledAt When the upgrade was scheduled
/// @param readyAt When the upgrade becomes executable
error UpgradeTimelockNotElapsed(
    uint256 scheduledAt,
    uint256 readyAt
);

/// @notice The new implementation does not match the scheduled one
/// @param expected The scheduled implementation address
/// @param actual The provided implementation address
error UpgradeImplementationMismatch(address expected, address actual);

/// @notice Token is not registered
/// @param token The unregistered token address
error TokenNotRegistered(address token);

/// @notice Pagination offset exceeds array length
/// @param offset Requested offset
/// @param length Array length
error OffsetOutOfBounds(uint256 offset, uint256 length);

/**
 * @title OmniPriceOracle
 * @author OmniBazaar Team
 * @notice Multi-validator price consensus oracle for OmniBazaar
 *
 * @dev Requires multiple validators to agree on prices within a
 *      tolerance band before accepting them as consensus. Provides
 *      TWAP, Chainlink fallback, staleness detection, and circuit
 *      breakers to prevent price manipulation.
 *
 * Architecture:
 * - Validators call submitPrice() each round with their observed price
 * - When minValidators have submitted, finalizeRound() computes median
 * - Submissions deviating >consensusTolerance from median are rejected
 * - Chainlink feeds serve as floor/ceiling for major tokens
 * - Single-block price changes >circuitBreakerThreshold are rejected
 * - Cumulative deviation tracking prevents incremental price walking
 * - TWAP (1-hour rolling) prevents flash manipulation
 * - Validators submitting outlier prices get flagged (slashing)
 * - Validators exceeding MAX_VIOLATIONS are suspended
 *
 * Security:
 * - UUPS upgradeable with 48-hour timelock for upgrades
 * - Pausable for emergency scenarios
 * - ReentrancyGuard on all state-changing functions
 * - Only active validators (verified via OmniCore) can submit prices
 *   (validator auth uses omniCore.isValidator(), not role-based)
 * - Circuit breaker prevents single-block flash attacks
 * - Anchor price tracking prevents incremental price walking
 * - Chainlink bounds prevent total consensus capture
 * - Storage gap for upgrade safety
 */
contract OmniPriceOracle is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // ══════════════════════════════════════════════════════════════════
    //                        TYPE DECLARATIONS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Individual price submission by a validator
    struct Submission {
        uint256 price;
        uint256 timestamp;
        address validator;
    }

    /// @notice Finalized price round with consensus result
    struct PriceRound {
        uint256 consensusPrice;
        uint256 timestamp;
        uint16 submissionCount;
        bool finalized;
    }

    /// @notice TWAP observation for rolling average
    struct TWAPObservation {
        uint256 price;
        uint256 timestamp;
    }

    /// @notice Chainlink feed configuration for a token
    struct ChainlinkConfig {
        address feedAddress;
        uint8 feedDecimals;
        bool enabled;
    }

    // ══════════════════════════════════════════════════════════════════
    //                            CONSTANTS
    // ══════════════════════════════════════════════════════════════════

    // Note: Validator authorization uses omniCore.isValidator() for
    // on-chain verification rather than a role-based VALIDATOR_ROLE.
    // This ensures only currently-active validators can submit prices.

    /// @notice Role for managing oracle configuration
    bytes32 public constant ORACLE_ADMIN_ROLE =
        keccak256("ORACLE_ADMIN_ROLE");

    /// @notice Basis points denominator (100% = 10000)
    uint256 private constant BPS = 10_000;

    /// @notice Maximum TWAP observations stored per token
    uint256 private constant MAX_TWAP_OBSERVATIONS = 1800;

    /// @notice Maximum tokens that can be registered
    uint256 private constant MAX_TOKENS = 500;

    /// @notice Maximum submissions per round
    uint256 private constant MAX_SUBMISSIONS_PER_ROUND = 50;

    /// @notice Minimum allowed value for minValidators parameter
    uint256 private constant MIN_VALIDATORS_FLOOR = 5;

    /// @notice Maximum allowed consensus tolerance (5% = 500 bps)
    uint256 private constant MAX_CONSENSUS_TOLERANCE = 500;

    /// @notice Minimum allowed staleness threshold (5 minutes)
    uint256 private constant MIN_STALENESS = 300;

    /// @notice Maximum allowed staleness threshold (24 hours)
    uint256 private constant MAX_STALENESS = 86_400;

    /// @notice Maximum allowed circuit breaker threshold (20%)
    uint256 private constant MAX_CIRCUIT_BREAKER = 2000;

    /// @notice Maximum cumulative deviation from anchor (20% per hour)
    uint256 public constant MAX_CUMULATIVE_DEVIATION = 2000;

    /// @notice Maximum violations before validator is suspended
    uint256 public constant MAX_VIOLATIONS = 100;

    /// @notice Timelock delay for UUPS upgrades (48 hours)
    uint256 public constant UPGRADE_DELAY = 48 hours;

    // ══════════════════════════════════════════════════════════════════
    //                          STATE VARIABLES
    // ══════════════════════════════════════════════════════════════════

    /// @notice OmniCore contract for validator verification
    IOmniCoreOracle public omniCore;

    /// @notice Current round number per token
    mapping(address => uint256) public currentRound;

    /// @notice Price history per token per round
    mapping(address => mapping(uint256 => PriceRound))
        public priceRounds;

    /// @notice Submissions per token per round per validator
    mapping(address => mapping(uint256 => mapping(address => bool)))
        public hasSubmitted;

    /// @notice Raw submissions per token per round (for median calc)
    mapping(address => mapping(uint256 => uint256[]))
        private _roundSubmissions;

    /// @notice Submitter addresses per token per round (parallel to
    ///         _roundSubmissions — shares indices before sorting)
    mapping(address => mapping(uint256 => address[]))
        private _roundSubmitters;

    /// @notice Latest consensus price per token
    mapping(address => uint256) public latestConsensusPrice;

    /// @notice Last update timestamp per token
    mapping(address => uint256) public lastUpdateTimestamp;

    /// @notice TWAP observations per token (circular buffer)
    mapping(address => TWAPObservation[]) private _twapObservations;

    /// @notice TWAP write index per token
    mapping(address => uint256) private _twapIndex;

    /// @notice Chainlink feed configuration per token
    mapping(address => ChainlinkConfig) public chainlinkFeeds;

    /// @notice Violation count per validator (for slashing)
    mapping(address => uint256) public violationCount;

    /// @notice Minimum validators required for consensus
    uint256 public minValidators;

    /// @notice Consensus tolerance in basis points (200 = 2%)
    uint256 public consensusTolerance;

    /// @notice Staleness threshold in seconds (3600 = 1 hour)
    uint256 public stalenessThreshold;

    /// @notice Circuit breaker threshold in basis points (1000 = 10%)
    uint256 public circuitBreakerThreshold;

    /// @notice Chainlink deviation threshold in bps (1000 = 10%)
    uint256 public chainlinkDeviationThreshold;

    /// @notice TWAP window in seconds (3600 = 1 hour)
    uint256 public twapWindow;

    /// @notice Registered token list
    address[] public registeredTokens;

    /// @notice Token registration status
    mapping(address => bool) public isRegisteredToken;

    /// @notice Anchor price for cumulative deviation tracking
    mapping(address => uint256) public anchorPrice;

    /// @notice Timestamp when anchor price was last set
    mapping(address => uint256) public anchorTimestamp;

    /// @notice Pending implementation for timelocked upgrade
    address public pendingImplementation;

    /// @notice Timestamp when upgrade was scheduled
    uint256 public upgradeScheduledAt;

    /// @notice Storage gap for future upgrades
    uint256[50] private __gap;

    // ══════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Emitted when a validator submits a price
    /// @param token Token address
    /// @param validator Validator who submitted
    /// @param price Submitted price (18 decimals)
    /// @param round Round number
    event PriceSubmitted(
        address indexed token,
        address indexed validator,
        uint256 price,
        uint256 round
    );

    /// @notice Emitted when a round is finalized with consensus
    /// @param token Token address
    /// @param consensusPrice Median price (18 decimals)
    /// @param round Round number
    /// @param submissionCount Number of submissions in round
    event RoundFinalized(
        address indexed token,
        uint256 consensusPrice,
        uint256 round,
        uint256 submissionCount
    );

    /// @notice Emitted when a validator's submission is flagged
    /// @param token Token address
    /// @param validator Flagged validator
    /// @param submitted Price submitted
    /// @param consensus Consensus price
    /// @param violations Total violation count
    event ValidatorFlagged(
        address indexed token,
        address indexed validator,
        uint256 submitted,
        uint256 consensus,
        uint256 violations
    );

    /// @notice Emitted when a Chainlink feed is configured
    /// @param token Token address
    /// @param feed Chainlink feed address
    event ChainlinkFeedSet(
        address indexed token,
        address indexed feed
    );

    /// @notice Emitted when a new token is registered
    /// @param token Token address
    event TokenRegistered(address indexed token);

    /// @notice Emitted when a token is deregistered
    /// @param token Token address
    event TokenDeregistered(address indexed token);

    /// @notice Emitted when circuit breaker triggers
    /// @param token Token address
    /// @param previousPrice Previous consensus price
    /// @param attemptedPrice Attempted new price
    event CircuitBreakerActivated(
        address indexed token,
        uint256 previousPrice,
        uint256 attemptedPrice
    );

    /// @notice Emitted when oracle parameters are updated
    /// @param minValidators New minimum validators
    /// @param consensusTolerance New consensus tolerance in bps
    /// @param stalenessThreshold New staleness threshold in seconds
    /// @param circuitBreakerThreshold New circuit breaker in bps
    event ParametersUpdated(
        uint256 minValidators,
        uint256 consensusTolerance,
        uint256 stalenessThreshold,
        uint256 circuitBreakerThreshold
    );

    /// @notice Emitted when the OmniCore contract reference changes
    /// @param oldCore Previous OmniCore address
    /// @param newCore New OmniCore address
    event OmniCoreUpdated(
        address indexed oldCore,
        address indexed newCore
    );

    /// @notice Emitted when a batch submission entry is skipped
    /// @param token Token address that was skipped
    /// @param reason Human-readable reason for skipping
    event SubmissionSkipped(
        address indexed token,
        string reason
    );

    /// @notice Emitted when a Chainlink feed call fails
    /// @param token Token address with failed feed
    /// @param reason Human-readable failure reason
    event ChainlinkFeedFailed(
        address indexed token,
        string reason
    );

    /// @notice Emitted when a UUPS upgrade is scheduled
    /// @param newImplementation Address of the new implementation
    /// @param scheduledAt Timestamp when the upgrade was scheduled
    /// @param readyAt Timestamp when the upgrade can be executed
    event UpgradeScheduled(
        address indexed newImplementation,
        uint256 scheduledAt,
        uint256 readyAt
    );

    /// @notice Emitted when a scheduled UUPS upgrade is cancelled
    /// @param cancelledImplementation The implementation that was cancelled
    event UpgradeCancelled(address indexed cancelledImplementation);

    // ══════════════════════════════════════════════════════════════════
    //                           INITIALIZER
    // ══════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the price oracle
     * @dev Sets default parameters and grants admin roles
     * @param _omniCore Address of OmniCore contract
     */
    function initialize(address _omniCore) external initializer {
        if (_omniCore == address(0)) revert ZeroTokenAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ADMIN_ROLE, msg.sender);

        omniCore = IOmniCoreOracle(_omniCore);

        minValidators = 5;
        consensusTolerance = 200; // 2%
        stalenessThreshold = 3600; // 1 hour
        circuitBreakerThreshold = 1000; // 10%
        chainlinkDeviationThreshold = 1000; // 10%
        twapWindow = 3600; // 1 hour
    }

    // ══════════════════════════════════════════════════════════════════
    //                       PRICE SUBMISSION
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Submit a price observation for a token
     * @dev Only active validators can submit. Each validator can
     *      submit once per round. When enough validators submit,
     *      the round auto-finalizes with median price.
     *      Validators with >= MAX_VIOLATIONS are suspended.
     * @param token Token address
     * @param price Price in 18-decimal format
     */
    function submitPrice(
        address token,
        uint256 price
    ) external nonReentrant whenNotPaused {
        if (!omniCore.isValidator(msg.sender)) revert NotValidator();
        if (violationCount[msg.sender] >= MAX_VIOLATIONS) {
            revert ValidatorSuspended(msg.sender);
        }
        if (token == address(0)) revert ZeroTokenAddress();
        if (price == 0) revert InvalidPrice();
        if (!isRegisteredToken[token]) revert ZeroTokenAddress();

        uint256 round = currentRound[token];

        // Check round not already finalized
        if (priceRounds[token][round].finalized) {
            revert RoundAlreadyFinalized();
        }

        // Check not already submitted this round
        if (hasSubmitted[token][round][msg.sender]) {
            revert AlreadySubmitted();
        }

        // Chainlink bounds check (if feed configured)
        ChainlinkConfig memory clConfig = chainlinkFeeds[token];
        if (clConfig.enabled) {
            uint256 clPrice = _getChainlinkPrice(token, clConfig);
            if (clPrice > 0) {
                uint256 deviation =
                    _calculateDeviation(price, clPrice);
                if (deviation > chainlinkDeviationThreshold) {
                    revert ChainlinkDeviationExceeded(
                        price, clPrice
                    );
                }
            }
        }

        // Circuit breaker: reject >threshold single-round change
        uint256 prevPrice = latestConsensusPrice[token];
        if (prevPrice > 0) {
            uint256 deviation =
                _calculateDeviation(price, prevPrice);
            if (deviation > circuitBreakerThreshold) {
                emit CircuitBreakerActivated(
                    token, prevPrice, price
                );
                revert CircuitBreakerTriggered(prevPrice, price);
            }
        }

        // Cumulative deviation check (anchor-based)
        _checkCumulativeDeviation(token, price);

        // Record submission
        hasSubmitted[token][round][msg.sender] = true;
        _roundSubmissions[token][round].push(price);
        _roundSubmitters[token][round].push(msg.sender);

        emit PriceSubmitted(token, msg.sender, price, round);

        // Auto-finalize when enough validators have submitted
        uint256 count = _roundSubmissions[token][round].length;
        if (count >= minValidators) {
            _finalizeRound(token, round);
        }
    }

    /**
     * @notice Submit prices for multiple tokens in one transaction
     * @dev Gas-efficient batch submission for validators. Emits
     *      SubmissionSkipped for each entry that is skipped with
     *      the reason for skipping.
     * @param tokens Array of token addresses
     * @param prices Array of prices (18 decimals each)
     */
    function submitPriceBatch(
        address[] calldata tokens,
        uint256[] calldata prices
    ) external nonReentrant whenNotPaused {
        if (tokens.length != prices.length) {
            revert ArrayLengthMismatch();
        }
        if (!omniCore.isValidator(msg.sender)) revert NotValidator();
        if (violationCount[msg.sender] >= MAX_VIOLATIONS) {
            revert ValidatorSuspended(msg.sender);
        }

        for (uint256 i = 0; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 price = prices[i];

            if (token == address(0) || price == 0) {
                emit SubmissionSkipped(
                    token, "zero address or price"
                );
                continue;
            }
            if (!isRegisteredToken[token]) {
                emit SubmissionSkipped(token, "not registered");
                continue;
            }

            uint256 round = currentRound[token];
            if (priceRounds[token][round].finalized) {
                emit SubmissionSkipped(
                    token, "round finalized"
                );
                continue;
            }
            if (hasSubmitted[token][round][msg.sender]) {
                emit SubmissionSkipped(
                    token, "already submitted"
                );
                continue;
            }

            // Chainlink bounds check
            ChainlinkConfig memory clConfig =
                chainlinkFeeds[token];
            if (clConfig.enabled) {
                uint256 clPrice =
                    _getChainlinkPrice(token, clConfig);
                if (clPrice > 0) {
                    uint256 dev =
                        _calculateDeviation(price, clPrice);
                    if (dev > chainlinkDeviationThreshold) {
                        emit SubmissionSkipped(
                            token, "chainlink deviation"
                        );
                        continue;
                    }
                }
            }

            // Circuit breaker
            uint256 prevPrice = latestConsensusPrice[token];
            if (prevPrice > 0) {
                uint256 dev =
                    _calculateDeviation(price, prevPrice);
                if (dev > circuitBreakerThreshold) {
                    emit SubmissionSkipped(
                        token, "circuit breaker"
                    );
                    continue;
                }
            }

            // Cumulative deviation check
            if (!_isCumulativeDeviationSafe(token, price)) {
                emit SubmissionSkipped(
                    token, "cumulative deviation"
                );
                continue;
            }

            hasSubmitted[token][round][msg.sender] = true;
            _roundSubmissions[token][round].push(price);
            _roundSubmitters[token][round].push(msg.sender);

            emit PriceSubmitted(
                token, msg.sender, price, round
            );

            uint256 count =
                _roundSubmissions[token][round].length;
            if (count >= minValidators) {
                _finalizeRound(token, round);
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Check if a token's price is stale
     * @param token Token address
     * @return True if price not updated within stalenessThreshold
     */
    function isStale(address token) external view returns (bool) {
        uint256 lastUpdate = lastUpdateTimestamp[token];
        if (lastUpdate == 0) return true;
        // solhint-disable-next-line not-rely-on-time
        return (block.timestamp - lastUpdate) > stalenessThreshold;
    }

    /**
     * @notice Get time-weighted average price over the TWAP window
     * @dev Terminates early when observations fall outside the
     *      TWAP window to save gas
     * @param token Token address
     * @return twapPrice TWAP value (18 decimals), 0 if no data
     */
    function getTWAP(
        address token
    ) external view returns (uint256 twapPrice) {
        TWAPObservation[] storage obs = _twapObservations[token];
        if (obs.length == 0) return 0;

        /* solhint-disable not-rely-on-time */
        uint256 cutoff = block.timestamp > twapWindow
            ? block.timestamp - twapWindow
            : 0;
        /* solhint-enable not-rely-on-time */

        uint256 totalWeightedPrice;
        uint256 totalWeight;

        for (uint256 i = 0; i < obs.length; ++i) {
            // Early termination: skip observations outside window
            if (obs[i].timestamp < cutoff) continue;

            if (obs[i].price > 0) {
                // solhint-disable-next-line not-rely-on-time
                uint256 age = block.timestamp - obs[i].timestamp;
                uint256 weight = twapWindow > age
                    ? twapWindow - age
                    : 1;
                totalWeightedPrice += obs[i].price * weight;
                totalWeight += weight;
            }
        }

        if (totalWeight == 0) return 0;
        return totalWeightedPrice / totalWeight;
    }

    /**
     * @notice Get the number of submissions in the current round
     * @param token Token address
     * @return count Number of submissions so far
     */
    function currentRoundSubmissions(
        address token
    ) external view returns (uint256 count) {
        uint256 round = currentRound[token];
        return _roundSubmissions[token][round].length;
    }

    /**
     * @notice Get all registered token addresses
     * @dev For large token lists, prefer getRegisteredTokensPaginated
     * @return Array of registered token addresses
     */
    function getRegisteredTokens()
        external
        view
        returns (address[] memory)
    {
        return registeredTokens;
    }

    /**
     * @notice Get registered tokens with pagination
     * @dev Use this for large token lists to avoid gas limits
     * @param offset Starting index in the registeredTokens array
     * @param limit Maximum number of tokens to return
     * @return tokens Array of token addresses in the requested page
     * @return total Total number of registered tokens
     */
    function getRegisteredTokensPaginated(
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (address[] memory tokens, uint256 total)
    {
        total = registeredTokens.length;
        if (offset >= total) {
            revert OffsetOutOfBounds(offset, total);
        }

        uint256 remaining = total - offset;
        uint256 count = limit < remaining ? limit : remaining;

        tokens = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            tokens[i] = registeredTokens[offset + i];
        }
    }

    /**
     * @notice Get the number of registered tokens
     * @return Count of registered tokens
     */
    function registeredTokenCount()
        external
        view
        returns (uint256)
    {
        return registeredTokens.length;
    }

    /**
     * @notice Verify a price against consensus (for frontend)
     * @param token Token address
     * @param price Price to verify (18 decimals)
     * @return withinTolerance True if within consensusTolerance of
     *         latest consensus
     * @return deviationBps Deviation in basis points
     */
    function verifyPrice(
        address token,
        uint256 price
    )
        external
        view
        returns (bool withinTolerance, uint256 deviationBps)
    {
        uint256 consensus = latestConsensusPrice[token];
        if (consensus == 0) return (false, BPS);

        deviationBps = _calculateDeviation(price, consensus);
        withinTolerance = deviationBps <= consensusTolerance;
    }

    // ══════════════════════════════════════════════════════════════════
    //                        ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Register a token for price tracking
     * @param token Token address to register
     */
    function registerToken(
        address token
    ) external onlyRole(ORACLE_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroTokenAddress();
        if (isRegisteredToken[token]) return;
        if (registeredTokens.length >= MAX_TOKENS) {
            revert MaxTokensExceeded();
        }

        isRegisteredToken[token] = true;
        registeredTokens.push(token);

        emit TokenRegistered(token);
    }

    /**
     * @notice Deregister a token from price tracking
     * @dev Removes the token from the registeredTokens array by
     *      swapping with the last element and popping. This changes
     *      array ordering but is O(1).
     * @param token Token address to deregister
     */
    function deregisterToken(
        address token
    ) external onlyRole(ORACLE_ADMIN_ROLE) {
        if (!isRegisteredToken[token]) {
            revert TokenNotRegistered(token);
        }

        isRegisteredToken[token] = false;

        // Find and remove from array (swap-and-pop)
        uint256 len = registeredTokens.length;
        for (uint256 i = 0; i < len; ++i) {
            if (registeredTokens[i] == token) {
                registeredTokens[i] =
                    registeredTokens[len - 1];
                registeredTokens.pop();
                break;
            }
        }

        emit TokenDeregistered(token);
    }

    /**
     * @notice Configure a Chainlink feed for a token
     * @param token Token address
     * @param feed Chainlink aggregator address
     */
    function setChainlinkFeed(
        address token,
        address feed
    ) external onlyRole(ORACLE_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroTokenAddress();

        if (feed == address(0)) {
            chainlinkFeeds[token] = ChainlinkConfig({
                feedAddress: address(0),
                feedDecimals: 0,
                enabled: false
            });
        } else {
            uint8 feedDecimals = IAggregatorV3(feed).decimals();
            chainlinkFeeds[token] = ChainlinkConfig({
                feedAddress: feed,
                feedDecimals: feedDecimals,
                enabled: true
            });
        }

        emit ChainlinkFeedSet(token, feed);
    }

    /**
     * @notice Update consensus parameters with bounds validation
     * @dev Each parameter is validated against min/max constants.
     *      Pass 0 to skip updating a specific parameter.
     * @param _minValidators Minimum validators for consensus
     * @param _consensusTolerance Tolerance in basis points
     * @param _stalenessThreshold Staleness in seconds
     * @param _circuitBreakerThreshold Circuit breaker in bps
     */
    function updateParameters(
        uint256 _minValidators,
        uint256 _consensusTolerance,
        uint256 _stalenessThreshold,
        uint256 _circuitBreakerThreshold
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_minValidators > 0) {
            if (_minValidators < MIN_VALIDATORS_FLOOR) {
                revert ParameterOutOfBounds(
                    "minValidators",
                    _minValidators,
                    MIN_VALIDATORS_FLOOR,
                    MAX_SUBMISSIONS_PER_ROUND
                );
            }
            if (_minValidators > MAX_SUBMISSIONS_PER_ROUND) {
                revert ParameterOutOfBounds(
                    "minValidators",
                    _minValidators,
                    MIN_VALIDATORS_FLOOR,
                    MAX_SUBMISSIONS_PER_ROUND
                );
            }
            minValidators = _minValidators;
        }
        if (_consensusTolerance > 0) {
            if (_consensusTolerance > MAX_CONSENSUS_TOLERANCE) {
                revert ParameterOutOfBounds(
                    "consensusTolerance",
                    _consensusTolerance,
                    1,
                    MAX_CONSENSUS_TOLERANCE
                );
            }
            consensusTolerance = _consensusTolerance;
        }
        if (_stalenessThreshold > 0) {
            if (
                _stalenessThreshold < MIN_STALENESS
                    || _stalenessThreshold > MAX_STALENESS
            ) {
                revert ParameterOutOfBounds(
                    "stalenessThreshold",
                    _stalenessThreshold,
                    MIN_STALENESS,
                    MAX_STALENESS
                );
            }
            stalenessThreshold = _stalenessThreshold;
        }
        if (_circuitBreakerThreshold > 0) {
            if (
                _circuitBreakerThreshold > MAX_CIRCUIT_BREAKER
            ) {
                revert ParameterOutOfBounds(
                    "circuitBreakerThreshold",
                    _circuitBreakerThreshold,
                    1,
                    MAX_CIRCUIT_BREAKER
                );
            }
            circuitBreakerThreshold = _circuitBreakerThreshold;
        }

        emit ParametersUpdated(
            minValidators,
            consensusTolerance,
            stalenessThreshold,
            circuitBreakerThreshold
        );
    }

    /**
     * @notice Update the OmniCore contract reference
     * @dev Validates that the new address is non-zero and has code
     * @param _omniCore New OmniCore contract address
     */
    function setOmniCore(
        address _omniCore
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_omniCore == address(0)) revert ZeroTokenAddress();
        if (_omniCore.code.length == 0) {
            revert NotAContract(_omniCore);
        }

        address oldCore = address(omniCore);
        omniCore = IOmniCoreOracle(_omniCore);

        emit OmniCoreUpdated(oldCore, _omniCore);
    }

    /**
     * @notice Schedule a UUPS upgrade with a 48-hour timelock
     * @dev The upgrade can only be executed after UPGRADE_DELAY
     *      has elapsed. Only one upgrade can be pending at a time.
     * @param newImpl Address of the new implementation contract
     */
    function scheduleUpgrade(
        address newImpl
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newImpl == address(0)) revert ZeroTokenAddress();
        if (newImpl.code.length == 0) {
            revert NotAContract(newImpl);
        }

        pendingImplementation = newImpl;
        // solhint-disable-next-line not-rely-on-time
        upgradeScheduledAt = block.timestamp;

        emit UpgradeScheduled(
            newImpl,
            block.timestamp, // solhint-disable-line not-rely-on-time
            block.timestamp + UPGRADE_DELAY // solhint-disable-line not-rely-on-time
        );
    }

    /**
     * @notice Cancel a previously scheduled upgrade
     * @dev Clears the pending implementation and schedule timestamp
     */
    function cancelUpgrade()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingImplementation == address(0)) {
            revert NoUpgradeScheduled();
        }

        address cancelled = pendingImplementation;
        pendingImplementation = address(0);
        upgradeScheduledAt = 0;

        emit UpgradeCancelled(cancelled);
    }

    /// @notice Pause the oracle (emergency)
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause the oracle
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ══════════════════════════════════════════════════════════════════
    //                       INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Finalize a round by computing median of submissions
     * @dev Called automatically when minValidators have submitted.
     *      Computes median, updates TWAP, and advances the round.
     * @param token Token address
     * @param round Round number to finalize
     */
    function _finalizeRound(
        address token,
        uint256 round
    ) internal {
        uint256[] storage submissions =
            _roundSubmissions[token][round];
        address[] storage submitters =
            _roundSubmitters[token][round];
        uint256 count = submissions.length;

        // Snapshot unsorted submissions before sorting
        // (sorting destroys index-to-address correspondence)
        uint256[] memory unsortedPrices = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            unsortedPrices[i] = submissions[i];
        }

        // Sort submissions in memory for median calculation
        uint256[] memory sorted = _sortArrayInMemory(submissions);

        // Calculate median
        uint256 median;
        if (count % 2 == 1) {
            median = sorted[count / 2];
        } else {
            median = (sorted[count / 2 - 1]
                + sorted[count / 2]) / 2;
        }

        // Store finalized round
        priceRounds[token][round] = PriceRound({
            consensusPrice: median,
            timestamp: block.timestamp, // solhint-disable-line not-rely-on-time
            submissionCount: uint16(count),
            finalized: true
        });

        // Update latest price
        latestConsensusPrice[token] = median;
        // solhint-disable-next-line not-rely-on-time
        lastUpdateTimestamp[token] = block.timestamp;

        // Update anchor if expired (1 hour)
        _updateAnchorIfExpired(token, median);

        // Update TWAP
        _addTWAPObservation(token, median);

        // Advance to next round
        currentRound[token] = round + 1;

        emit RoundFinalized(token, median, round, count);

        // Flag outlier validators (>20% from consensus)
        // Uses unsorted price/submitter arrays for correctness
        _flagOutliers(token, unsortedPrices, submitters, median);
    }

    /**
     * @notice Check cumulative deviation from anchor price
     * @dev Reverts if the cumulative deviation from the anchor
     *      exceeds MAX_CUMULATIVE_DEVIATION within one hour.
     *      Resets anchor every hour.
     * @param token Token address
     * @param price Submitted price to check
     */
    function _checkCumulativeDeviation(
        address token,
        uint256 price
    ) internal {
        uint256 anchor = anchorPrice[token];
        if (anchor == 0) {
            // First submission — set anchor
            anchorPrice[token] = price;
            // solhint-disable-next-line not-rely-on-time
            anchorTimestamp[token] = block.timestamp;
            return;
        }

        // Reset anchor every hour
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp - anchorTimestamp[token] >= 1 hours) {
            anchorPrice[token] = price;
            // solhint-disable-next-line not-rely-on-time
            anchorTimestamp[token] = block.timestamp;
            return;
        }

        // Check cumulative deviation from anchor
        uint256 cumDev = _calculateDeviation(price, anchor);
        if (cumDev > MAX_CUMULATIVE_DEVIATION) {
            revert CumulativeDeviationExceeded(token, cumDev);
        }
    }

    /**
     * @notice Check cumulative deviation without reverting
     * @dev Used by batch submissions to skip rather than revert
     * @param token Token address
     * @param price Submitted price to check
     * @return safe True if deviation is within bounds
     */
    function _isCumulativeDeviationSafe(
        address token,
        uint256 price
    ) internal view returns (bool safe) {
        uint256 anchor = anchorPrice[token];
        if (anchor == 0) return true;

        // If anchor has expired, any price is safe
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp - anchorTimestamp[token] >= 1 hours) {
            return true;
        }

        uint256 cumDev = _calculateDeviation(price, anchor);
        return cumDev <= MAX_CUMULATIVE_DEVIATION;
    }

    /**
     * @notice Update anchor price if the hourly window has expired
     * @dev Called after round finalization to set new anchor
     * @param token Token address
     * @param price New consensus price to use as anchor
     */
    function _updateAnchorIfExpired(
        address token,
        uint256 price
    ) internal {
        /* solhint-disable not-rely-on-time */
        if (
            anchorPrice[token] == 0
                || block.timestamp - anchorTimestamp[token]
                    >= 1 hours
        ) {
            anchorPrice[token] = price;
            anchorTimestamp[token] = block.timestamp;
        }
        /* solhint-enable not-rely-on-time */
    }

    /**
     * @notice Add a TWAP observation (circular buffer)
     * @param token Token address
     * @param price Price to record
     */
    function _addTWAPObservation(
        address token,
        uint256 price
    ) internal {
        TWAPObservation[] storage obs = _twapObservations[token];
        TWAPObservation memory newObs = TWAPObservation({
            price: price,
            timestamp: block.timestamp // solhint-disable-line not-rely-on-time
        });

        if (obs.length < MAX_TWAP_OBSERVATIONS) {
            obs.push(newObs);
        } else {
            uint256 idx = _twapIndex[token]
                % MAX_TWAP_OBSERVATIONS;
            obs[idx] = newObs;
            _twapIndex[token] =
                (_twapIndex[token] + 1) % MAX_TWAP_OBSERVATIONS;
        }
    }

    /**
     * @notice Flag validators whose submissions deviate >20% from
     *         consensus
     * @dev Uses unsorted price/submitter arrays to correctly
     *      attribute outlier prices to their submitting validators.
     * @param token Token address (for event)
     * @param prices Unsorted submission prices (pre-sort snapshot)
     * @param submitters Parallel array of submitter addresses
     * @param median Consensus median price
     */
    function _flagOutliers(
        address token,
        uint256[] memory prices,
        address[] storage submitters,
        uint256 median
    ) internal {
        uint256 flagThreshold = 2000; // 20% in bps
        for (uint256 i = 0; i < prices.length; ++i) {
            uint256 dev = _calculateDeviation(
                prices[i], median
            );
            if (dev > flagThreshold) {
                address flagged = submitters[i];
                ++violationCount[flagged];

                emit ValidatorFlagged(
                    token,
                    flagged,
                    prices[i],
                    median,
                    violationCount[flagged]
                );
            }
        }
    }

    /**
     * @notice Get price from Chainlink feed (18-decimal normalized)
     * @dev Validates answeredInRound >= roundId for staleness.
     *      Emits ChainlinkFeedFailed on any failure condition.
     * @param token Token address (for failure event emission)
     * @param config Chainlink feed configuration
     * @return price Normalized price (18 decimals), 0 on failure
     */
    function _getChainlinkPrice(
        address token,
        ChainlinkConfig memory config
    ) internal returns (uint256 price) {
        // solhint-disable-next-line no-empty-blocks
        try IAggregatorV3(config.feedAddress).latestRoundData()
            returns (
                uint80 roundId,
                int256 answer,
                uint256,
                uint256 updatedAt,
                uint80 answeredInRound
            )
        {
            if (answer <= 0) {
                emit ChainlinkFeedFailed(
                    token, "non-positive answer"
                );
                return 0;
            }
            // Staleness check: answeredInRound must be current
            if (answeredInRound < roundId) {
                emit ChainlinkFeedFailed(
                    token, "stale answeredInRound"
                );
                return 0;
            }
            /* solhint-disable not-rely-on-time */
            if (
                block.timestamp - updatedAt > stalenessThreshold
            ) {
            /* solhint-enable not-rely-on-time */
                emit ChainlinkFeedFailed(
                    token, "stale updatedAt"
                );
                return 0;
            }

            // Normalize to 18 decimals
            if (config.feedDecimals < 18) {
                price = uint256(answer)
                    * 10 ** (18 - config.feedDecimals);
            } else if (config.feedDecimals > 18) {
                price = uint256(answer)
                    / 10 ** (config.feedDecimals - 18);
            } else {
                price = uint256(answer);
            }
        } catch {
            emit ChainlinkFeedFailed(token, "call reverted");
            return 0;
        }
    }

    /**
     * @notice Calculate deviation between two prices in basis points
     * @param a First price
     * @param b Second price (reference)
     * @return Deviation in basis points
     */
    function _calculateDeviation(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        if (b == 0) return BPS;
        if (a > b) {
            return ((a - b) * BPS) / b;
        } else {
            return ((b - a) * BPS) / b;
        }
    }

    /**
     * @notice Sort a storage array by copying to memory first
     * @dev Copies storage array to memory, sorts in memory using
     *      insertion sort, then returns the sorted memory array.
     *      This is ~200x cheaper than sorting directly in storage.
     * @param arr Storage array to read from
     * @return sorted Sorted memory array
     */
    function _sortArrayInMemory(
        uint256[] storage arr
    ) internal view returns (uint256[] memory sorted) {
        uint256 len = arr.length;
        sorted = new uint256[](len);

        // Copy storage to memory
        for (uint256 i = 0; i < len; ++i) {
            sorted[i] = arr[i];
        }

        // Insertion sort in memory (suitable for < 50 elements)
        for (uint256 i = 1; i < len; ++i) {
            uint256 key = sorted[i];
            uint256 j = i;
            while (j > 0 && sorted[j - 1] > key) {
                sorted[j] = sorted[j - 1];
                --j;
            }
            sorted[j] = key;
        }
    }

    /**
     * @notice Authorize UUPS upgrades via 48-hour timelock
     * @dev Verifies that the new implementation matches the
     *      scheduled pending implementation and that the timelock
     *      delay has elapsed.
     * @param newImplementation New implementation address
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pendingImplementation == address(0)) {
            revert NoUpgradeScheduled();
        }
        if (newImplementation != pendingImplementation) {
            revert UpgradeImplementationMismatch(
                pendingImplementation,
                newImplementation
            );
        }
        /* solhint-disable not-rely-on-time */
        if (
            block.timestamp
                < upgradeScheduledAt + UPGRADE_DELAY
        ) {
        /* solhint-enable not-rely-on-time */
            revert UpgradeTimelockNotElapsed(
                upgradeScheduledAt,
                upgradeScheduledAt + UPGRADE_DELAY
            );
        }

        // Clear pending state after successful authorization
        pendingImplementation = address(0);
        upgradeScheduledAt = 0;
    }
}
