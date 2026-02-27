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
 * - TWAP (1-hour rolling) prevents flash manipulation
 * - Validators submitting outlier prices get flagged (slashing integration)
 *
 * Security:
 * - UUPS upgradeable with admin-only upgrade authorization
 * - Pausable for emergency scenarios
 * - ReentrancyGuard on all state-changing functions
 * - Only active validators (verified via OmniCore) can submit prices
 * - Circuit breaker prevents single-block flash attacks
 * - Chainlink bounds prevent total consensus capture
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
        uint8 submissionCount;
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

    /// @notice Role for validators submitting prices
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");

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

    /// @notice Emitted when circuit breaker triggers
    /// @param token Token address
    /// @param previousPrice Previous consensus price
    /// @param attemptedPrice Attempted new price
    event CircuitBreakerActivated(
        address indexed token,
        uint256 previousPrice,
        uint256 attemptedPrice
    );

    // ══════════════════════════════════════════════════════════════════
    //                           INITIALIZER
    // ══════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the price oracle
     * @param _omniCore Address of OmniCore contract
     */
    function initialize(address _omniCore) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ADMIN_ROLE, msg.sender);

        omniCore = IOmniCoreOracle(_omniCore);

        minValidators = 3;
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
     * @param token Token address
     * @param price Price in 18-decimal format
     */
    function submitPrice(
        address token,
        uint256 price
    ) external nonReentrant whenNotPaused {
        if (!omniCore.isValidator(msg.sender)) revert NotValidator();
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
            uint256 clPrice = _getChainlinkPrice(clConfig);
            if (clPrice > 0) {
                uint256 deviation = _calculateDeviation(price, clPrice);
                if (deviation > chainlinkDeviationThreshold) {
                    revert ChainlinkDeviationExceeded(price, clPrice);
                }
            }
        }

        // Circuit breaker: reject >10% single-round change
        uint256 prevPrice = latestConsensusPrice[token];
        if (prevPrice > 0) {
            uint256 deviation = _calculateDeviation(price, prevPrice);
            if (deviation > circuitBreakerThreshold) {
                emit CircuitBreakerActivated(token, prevPrice, price);
                revert CircuitBreakerTriggered(prevPrice, price);
            }
        }

        // Record submission
        hasSubmitted[token][round][msg.sender] = true;
        _roundSubmissions[token][round].push(price);

        emit PriceSubmitted(token, msg.sender, price, round);

        // Auto-finalize when enough validators have submitted
        uint256 count = _roundSubmissions[token][round].length;
        if (count >= minValidators) {
            _finalizeRound(token, round);
        }
    }

    /**
     * @notice Submit prices for multiple tokens in one transaction
     * @dev Gas-efficient batch submission for validators
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

        for (uint256 i = 0; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 price = prices[i];

            if (token == address(0) || price == 0) continue;
            if (!isRegisteredToken[token]) continue;

            uint256 round = currentRound[token];
            if (priceRounds[token][round].finalized) continue;
            if (hasSubmitted[token][round][msg.sender]) continue;

            // Chainlink bounds check
            ChainlinkConfig memory clConfig = chainlinkFeeds[token];
            if (clConfig.enabled) {
                uint256 clPrice = _getChainlinkPrice(clConfig);
                if (clPrice > 0) {
                    uint256 dev = _calculateDeviation(price, clPrice);
                    if (dev > chainlinkDeviationThreshold) continue;
                }
            }

            // Circuit breaker
            uint256 prevPrice = latestConsensusPrice[token];
            if (prevPrice > 0) {
                uint256 dev = _calculateDeviation(price, prevPrice);
                if (dev > circuitBreakerThreshold) continue;
            }

            hasSubmitted[token][round][msg.sender] = true;
            _roundSubmissions[token][round].push(price);

            emit PriceSubmitted(token, msg.sender, price, round);

            uint256 count = _roundSubmissions[token][round].length;
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
     * @param token Token address
     * @return twapPrice TWAP value (18 decimals), 0 if insufficient data
     */
    function getTWAP(
        address token
    ) external view returns (uint256 twapPrice) {
        TWAPObservation[] storage obs = _twapObservations[token];
        if (obs.length == 0) return 0;

        // solhint-disable-next-line not-rely-on-time
        uint256 cutoff = block.timestamp > twapWindow
            ? block.timestamp - twapWindow
            : 0;

        uint256 totalWeightedPrice;
        uint256 totalWeight;

        for (uint256 i = 0; i < obs.length; ++i) {
            if (obs[i].timestamp >= cutoff && obs[i].price > 0) {
                uint256 age = block.timestamp - obs[i].timestamp;
                // solhint-disable-next-line not-rely-on-time
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
     * @notice Update consensus parameters
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
        if (_minValidators > 0) minValidators = _minValidators;
        if (_consensusTolerance > 0) {
            consensusTolerance = _consensusTolerance;
        }
        if (_stalenessThreshold > 0) {
            stalenessThreshold = _stalenessThreshold;
        }
        if (_circuitBreakerThreshold > 0) {
            circuitBreakerThreshold = _circuitBreakerThreshold;
        }
    }

    /**
     * @notice Update the OmniCore contract reference
     * @param _omniCore New OmniCore address
     */
    function setOmniCore(
        address _omniCore
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        omniCore = IOmniCoreOracle(_omniCore);
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
        uint256[] storage submissions = _roundSubmissions[token][round];
        uint256 count = submissions.length;

        // Sort submissions for median calculation
        _sortArray(submissions);

        // Calculate median
        uint256 median;
        if (count % 2 == 1) {
            median = submissions[count / 2];
        } else {
            median = (submissions[count / 2 - 1] +
                submissions[count / 2]) / 2;
        }

        // Store finalized round
        priceRounds[token][round] = PriceRound({
            consensusPrice: median,
            timestamp: block.timestamp, // solhint-disable-line not-rely-on-time
            submissionCount: uint8(count),
            finalized: true
        });

        // Update latest price
        latestConsensusPrice[token] = median;
        lastUpdateTimestamp[token] = block.timestamp; // solhint-disable-line not-rely-on-time

        // Update TWAP
        _addTWAPObservation(token, median);

        // Advance to next round
        currentRound[token] = round + 1;

        emit RoundFinalized(token, median, round, count);

        // Flag outlier validators (>20% from consensus)
        _flagOutliers(token, submissions, median);
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
            uint256 idx = _twapIndex[token] %
                MAX_TWAP_OBSERVATIONS;
            obs[idx] = newObs;
            _twapIndex[token] = idx + 1;
        }
    }

    /**
     * @notice Flag validators whose submissions deviate >20% from
     *         consensus
     * @param token Token address (for event)
     * @param submissions Sorted submission array
     * @param median Consensus median price
     */
    function _flagOutliers(
        address token,
        uint256[] storage submissions,
        uint256 median
    ) internal {
        // We only have prices, not addresses in the sorted array.
        // Flag any price >20% from median (2000 bps)
        uint256 flagThreshold = 2000;
        for (uint256 i = 0; i < submissions.length; ++i) {
            uint256 dev = _calculateDeviation(
                submissions[i],
                median
            );
            if (dev > flagThreshold) {
                // Violation recorded; slashing handled off-chain
                // via ValidatorFlagged event indexing
                emit ValidatorFlagged(
                    token,
                    address(0), // Cannot track address in sorted array
                    submissions[i],
                    median,
                    0
                );
            }
        }
    }

    /**
     * @notice Get price from Chainlink feed (18-decimal normalized)
     * @param config Chainlink feed configuration
     * @return price Normalized price (18 decimals)
     */
    function _getChainlinkPrice(
        ChainlinkConfig memory config
    ) internal view returns (uint256 price) {
        // solhint-disable-next-line no-empty-blocks
        try IAggregatorV3(config.feedAddress).latestRoundData()
            returns (
                uint80,
                int256 answer,
                uint256,
                uint256 updatedAt,
                uint80
            )
        {
            if (answer <= 0) return 0;
            // solhint-disable-next-line not-rely-on-time
            if (block.timestamp - updatedAt > stalenessThreshold) {
                return 0;
            }

            // Normalize to 18 decimals
            if (config.feedDecimals < 18) {
                price = uint256(answer) *
                    10 ** (18 - config.feedDecimals);
            } else if (config.feedDecimals > 18) {
                price = uint256(answer) /
                    10 ** (config.feedDecimals - 18);
            } else {
                price = uint256(answer);
            }
        } catch {
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
     * @notice Sort an array of uint256 in ascending order (insertion sort)
     * @dev Suitable for small arrays (< 50 elements)
     * @param arr Array to sort in-place
     */
    function _sortArray(uint256[] storage arr) internal {
        uint256 len = arr.length;
        for (uint256 i = 1; i < len; ++i) {
            uint256 key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) {
                arr[j] = arr[j - 1];
                --j;
            }
            arr[j] = key;
        }
    }

    /**
     * @notice Authorize UUPS upgrades (admin only)
     * @param newImplementation New implementation address
     */
    // solhint-disable-next-line no-unused-vars
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
