// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title DEXSettlement
 * @author OmniCoin Development Team
 * @notice Trustless on-chain trade settlement with commit-reveal MEV protection
 * @dev Atomic settlement of matched orders with dual signature verification
 *
 * Architecture (Trustless):
 * 1. Users commit order hash (optional, for MEV protection)
 * 2. Users reveal and sign orders with EIP-712
 * 3. Validators match orders off-chain
 * 4. ANYONE can submit matched orders for settlement
 * 5. Contract verifies signatures + matching logic
 * 6. Atomic swap executed, fees distributed
 *
 * Key Security Features:
 * - No single validator controls settlement (anyone can submit)
 * - Dual signature verification (both parties must sign)
 * - Contract verifies order matching logic
 * - Commit-reveal prevents front-running
 * - Fee attribution to matching validator (not submitter)
 * - Emergency circuit breakers
 * - Slippage protection
 *
 * Fee Distribution:
 * - 70% → Liquidity/Staking Pool (incentivizes liquidity)
 * - 20% → ODDAO (governance operations)
 * - 10% → Protocol (ongoing development)
 */
contract DEXSettlement is EIP712, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice EIP-712 type hash for Order struct
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address trader,bool isBuy,address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOut,uint256 price,uint256 deadline,bytes32 salt,address matchingValidator,uint256 nonce)"
    );

    /// @notice Minimum blocks to wait between commit and reveal
    uint256 public constant MIN_COMMIT_BLOCKS = 2;

    /// @notice Maximum blocks to wait for reveal after commit
    uint256 public constant MAX_COMMIT_BLOCKS = 100;

    /// @notice Maximum slippage in basis points (10% = 1000)
    uint256 public constant MAX_SLIPPAGE_BPS = 1000;

    /// @notice Basis points divisor (100%)
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    /// @notice Liquidity/Staking pool fee share (70%)
    uint256 public constant LIQUIDITY_POOL_SHARE = 7000;

    /// @notice ODDAO fee share (20%)
    uint256 public constant ODDAO_SHARE = 2000;

    /// @notice Protocol fee share (10%)
    uint256 public constant PROTOCOL_SHARE = 1000;

    /// @notice Spot market maker fee (0.1%)
    uint256 public constant SPOT_MAKER_FEE = 10;

    /// @notice Spot market taker fee (0.2%)
    uint256 public constant SPOT_TAKER_FEE = 20;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /**
     * @notice Emitted when an order is committed (commit phase)
     * @param trader Trader address
     * @param orderHash Hash of the order
     * @param commitBlock Block number of commitment
     */
    event OrderCommitted(
        address indexed trader,
        bytes32 indexed orderHash,
        uint256 commitBlock
    );

    /**
     * @notice Emitted when a trade is settled
     * @param tradeId Unique trade identifier
     * @param maker Address of the maker
     * @param taker Address of the taker
     * @param tokenIn Token being sold
     * @param tokenOut Token being bought
     * @param amountIn Amount of tokenIn
     * @param amountOut Amount of tokenOut
     * @param makerFee Fee paid by maker
     * @param takerFee Fee paid by taker
     * @param matchingValidator Validator who matched the orders
     * @param settler Address that submitted the settlement
     */
    event TradeSettled(
        bytes32 indexed tradeId,
        address indexed maker,
        address indexed taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 makerFee,
        uint256 takerFee,
        address matchingValidator,
        address settler
    );

    /**
     * @notice Emitted when fees are distributed
     * @param matchingValidator Validator who matched the trade
     * @param liquidityPoolAmount Amount to liquidity/staking pool
     * @param oddaoAmount Amount to ODDAO
     * @param protocolAmount Amount to protocol
     * @param timestamp Distribution timestamp
     */
    event FeesDistributed(
        address indexed matchingValidator,
        uint256 liquidityPoolAmount,
        uint256 oddaoAmount,
        uint256 protocolAmount,
        uint256 timestamp
    );

    /**
     * @notice Emitted when accrued fees are claimed by a recipient
     * @param recipient Address claiming fees
     * @param token Token claimed
     * @param amount Amount claimed
     */
    event FeesClaimed(
        address indexed recipient,
        address indexed token,
        uint256 amount
    );

    /**
     * @notice Emitted when emergency stop is triggered
     * @param triggeredBy Address that triggered the stop
     * @param reason Reason for emergency stop
     */
    event EmergencyStop(address indexed triggeredBy, string reason);

    /**
     * @notice Emitted when trading is resumed
     * @param triggeredBy Address that resumed trading
     */
    event TradingResumed(address indexed triggeredBy);

    /**
     * @notice Emitted when trading limits are updated
     * @param maxTradeSize New maximum trade size
     * @param dailyVolumeLimit New daily volume limit
     * @param maxSlippageBps New maximum slippage in basis points
     */
    event TradingLimitsUpdated(
        uint256 indexed maxTradeSize,
        uint256 indexed dailyVolumeLimit,
        uint256 maxSlippageBps
    );

    // ========================================================================
    // CUSTOM ERRORS
    // ========================================================================

    /// @notice Thrown when emergency stop is activated
    error EmergencyStopActive();

    /// @notice Thrown when order has expired
    error OrderExpired();

    /// @notice Thrown when order signature is invalid
    error InvalidSignature();

    /// @notice Thrown when orders don't match
    error OrdersDontMatch();

    /// @notice Thrown when order is already filled
    error OrderAlreadyFilled();

    /// @notice Thrown when self-trading is attempted
    error SelfTradingNotAllowed();

    /// @notice Thrown when token balance is insufficient
    error InsufficientBalance(address token, address account);

    /// @notice Thrown when token allowance is insufficient
    error InsufficientAllowance(address token, address account);

    /// @notice Thrown when slippage exceeds maximum
    error SlippageExceedsMaximum();

    /// @notice Thrown when trade size exceeds limit
    error TradeSizeExceedsLimit();

    /// @notice Thrown when daily volume limit is exceeded
    error DailyVolumeLimitExceeded();

    /// @notice Thrown when commitment doesn't exist
    error CommitmentNotFound();

    /// @notice Thrown when revealing too early
    error RevealTooEarly();

    /// @notice Thrown when revealing too late
    error RevealTooLate();

    /// @notice Thrown when commitment hash doesn't match
    error CommitmentHashMismatch();

    /// @notice Thrown when matching validators don't agree
    error MatchingValidatorMismatch();

    /// @notice Thrown when address is invalid
    error InvalidAddress();

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when fee shares don't sum to 100%
    error InvalidFeeShares();

    // ========================================================================
    // STRUCTS
    // ========================================================================

    /**
     * @notice Order structure for EIP-712 signing
     * @param trader Address of the trader
     * @param isBuy True if buy order, false if sell order
     * @param tokenIn Token being sold
     * @param tokenOut Token being bought
     * @param amountIn Amount of tokenIn
     * @param amountOut Amount of tokenOut
     * @param price Price in basis points (for matching verification)
     * @param deadline Order expiration timestamp
     * @param salt Random value for uniqueness (commit-reveal)
     * @param matchingValidator Validator expected to match this order
     * @param nonce Unique nonce to prevent replay
     */
    struct Order {
        address trader;
        bool isBuy;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        uint256 price;
        uint256 deadline;
        bytes32 salt;
        address matchingValidator;
        uint256 nonce;
    }

    /**
     * @notice Order commitment for MEV protection
     * @param orderHash Hash of the order
     * @param commitBlock Block number when committed
     * @param revealed Whether order has been revealed
     */
    struct Commitment {
        bytes32 orderHash;
        uint256 commitBlock;
        bool revealed;
    }

    /**
     * @notice Fee distribution addresses
     * @param liquidityPool Address of liquidity/staking pool
     * @param oddao Address of ODDAO treasury
     * @param protocol Address of protocol treasury
     */
    struct FeeRecipients {
        address liquidityPool;
        address oddao;
        address protocol;
    }

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice Mapping of trader => orderHash => commitment
    mapping(address => mapping(bytes32 => Commitment)) public commitments;

    /// @notice Mapping of orderHash => filled status
    mapping(bytes32 => bool) public filledOrders;

    /// @notice Mapping of trader => nonce for replay protection
    mapping(address => uint256) public nonces;

    /// @notice Fee recipient addresses
    FeeRecipients public feeRecipients;

    /// @notice Total trading volume
    uint256 public totalTradingVolume;

    /// @notice Total fees collected
    uint256 public totalFeesCollected;

    /// @notice Emergency stop flag
    bool public emergencyStop;

    /// @notice Maximum trade size
    uint256 public maxTradeSize;

    /// @notice Daily volume limit
    uint256 public dailyVolumeLimit;

    /// @notice Daily volume used
    uint256 public dailyVolumeUsed;

    /// @notice Last reset day for volume tracking
    uint256 public lastResetDay;

    /// @notice Maximum slippage in basis points
    uint256 public maxSlippageBps;

    /// @notice Accrued fees per recipient per token (recipient => token => amount)
    mapping(address => mapping(address => uint256)) public accruedFees;

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /**
     * @notice Constructor to initialize the DEXSettlement contract
     * @param _liquidityPool Address of liquidity/staking pool
     * @param _oddao Address of ODDAO treasury
     * @param _protocol Address of protocol treasury
     */
    constructor(
        address _liquidityPool,
        address _oddao,
        address _protocol
    ) EIP712("OmniCoin DEX Settlement", "1") Ownable(msg.sender) {
        if (_liquidityPool == address(0) || _oddao == address(0) || _protocol == address(0)) {
            revert InvalidAddress();
        }

        feeRecipients = FeeRecipients({
            liquidityPool: _liquidityPool,
            oddao: _oddao,
            protocol: _protocol
        });

        // Initialize default limits
        maxSlippageBps = 500; // 5% default max slippage
        maxTradeSize = 1_000_000 * 10 ** 18; // 1M tokens default
        dailyVolumeLimit = 10_000_000 * 10 ** 18; // 10M tokens daily
        lastResetDay = block.timestamp / 1 days;
    }

    // ========================================================================
    // EXTERNAL FUNCTIONS - COMMIT-REVEAL
    // ========================================================================

    /**
     * @notice Commit order hash (Phase 1 of commit-reveal)
     * @param orderHash Hash of the order to commit
     * @dev Users commit before revealing to prevent front-running
     */
    function commitOrder(bytes32 orderHash) external {
        if (orderHash == bytes32(0)) revert InvalidAddress();

        commitments[msg.sender][orderHash] = Commitment({
            orderHash: orderHash,
            commitBlock: block.number,
            revealed: false
        });

        emit OrderCommitted(msg.sender, orderHash, block.number);
    }

    /**
     * @notice Reveal order after commitment (Phase 2 of commit-reveal)
     * @param order Order details
     * @dev Verifies commitment exists and timing is correct
     */
    function revealOrder(Order calldata order) external {
        if (order.trader != msg.sender) revert InvalidSignature();

        bytes32 orderHash = _hashOrder(order);
        Commitment storage commitment = commitments[msg.sender][orderHash];

        if (commitment.commitBlock == 0) revert CommitmentNotFound();
        if (commitment.revealed) revert OrderAlreadyFilled();
        if (block.number < commitment.commitBlock + MIN_COMMIT_BLOCKS) {
            revert RevealTooEarly();
        }
        if (block.number > commitment.commitBlock + MAX_COMMIT_BLOCKS) {
            revert RevealTooLate();
        }

        commitment.revealed = true;
    }

    // ========================================================================
    // EXTERNAL FUNCTIONS - SETTLEMENT
    // ========================================================================

    /**
     * @notice Settle a matched trade (TRUSTLESS - anyone can call)
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @param makerSignature Maker's EIP-712 signature
     * @param takerSignature Taker's EIP-712 signature
     * @dev Verifies both signatures, order matching logic, and executes atomic swap
     */
    function settleTrade(
        Order calldata makerOrder,
        Order calldata takerOrder,
        bytes calldata makerSignature,
        bytes calldata takerSignature
    ) external nonReentrant whenNotPaused {
        if (emergencyStop) revert EmergencyStopActive();

        // Reset daily volume if new day
        if (block.timestamp / 1 days > lastResetDay) {
            dailyVolumeUsed = 0;
            lastResetDay = block.timestamp / 1 days;
        }

        // Verify orders not expired
        if (block.timestamp > makerOrder.deadline) revert OrderExpired();
        if (block.timestamp > takerOrder.deadline) revert OrderExpired();

        // Verify different traders (no self-trading)
        if (makerOrder.trader == takerOrder.trader) revert SelfTradingNotAllowed();

        // Verify matching validators agree
        if (makerOrder.matchingValidator != takerOrder.matchingValidator) {
            revert MatchingValidatorMismatch();
        }

        // Verify signatures (EIP-712)
        bytes32 makerHash = _hashTypedDataV4(_hashOrder(makerOrder));
        bytes32 takerHash = _hashTypedDataV4(_hashOrder(takerOrder));

        if (makerHash.recover(makerSignature) != makerOrder.trader) {
            revert InvalidSignature();
        }
        if (takerHash.recover(takerSignature) != takerOrder.trader) {
            revert InvalidSignature();
        }

        // Verify orders not already filled
        if (filledOrders[makerHash]) revert OrderAlreadyFilled();
        if (filledOrders[takerHash]) revert OrderAlreadyFilled();

        // Verify nonces are current (prevent replay)
        if (makerOrder.nonce != nonces[makerOrder.trader]) revert InvalidSignature();
        if (takerOrder.nonce != nonces[takerOrder.trader]) revert InvalidSignature();

        // Verify order matching logic
        _verifyOrdersMatch(makerOrder, takerOrder);

        // Check volume limits
        if (makerOrder.amountIn > maxTradeSize || takerOrder.amountIn > maxTradeSize) {
            revert TradeSizeExceedsLimit();
        }
        if (dailyVolumeUsed + makerOrder.amountIn > dailyVolumeLimit) {
            revert DailyVolumeLimitExceeded();
        }

        // Check balances and allowances
        _checkBalancesAndAllowances(makerOrder, takerOrder);

        // Calculate fees
        uint256 makerFee = (makerOrder.amountOut * SPOT_MAKER_FEE) / BASIS_POINTS_DIVISOR;
        uint256 takerFee = (takerOrder.amountOut * SPOT_TAKER_FEE) / BASIS_POINTS_DIVISOR;

        // Execute atomic settlement
        _executeAtomicSettlement(makerOrder, takerOrder, makerFee, takerFee);

        // Mark orders as filled
        filledOrders[makerHash] = true;
        filledOrders[takerHash] = true;

        // Increment nonces
        ++nonces[makerOrder.trader];
        ++nonces[takerOrder.trader];

        // Update volume tracking
        totalTradingVolume += makerOrder.amountIn;
        dailyVolumeUsed += makerOrder.amountIn;

        // Distribute fees to matching validator (NOT msg.sender!)
        _distributeFees(
            makerFee, takerFee,
            makerOrder.tokenOut, takerOrder.tokenOut,
            makerOrder.matchingValidator
        );

        // Generate trade ID
        bytes32 tradeId = keccak256(abi.encodePacked(makerHash, takerHash));

        emit TradeSettled(
            tradeId,
            makerOrder.trader,
            takerOrder.trader,
            makerOrder.tokenIn,
            makerOrder.tokenOut,
            makerOrder.amountIn,
            makerOrder.amountOut,
            makerFee,
            takerFee,
            makerOrder.matchingValidator,
            msg.sender // The settler (can be anyone!)
        );
    }

    // ========================================================================
    // EXTERNAL FUNCTIONS - ADMIN
    // ========================================================================

    /**
     * @notice Update fee recipient addresses
     * @param _liquidityPool New liquidity pool address
     * @param _oddao New ODDAO address
     * @param _protocol New protocol address
     * @dev Can only be called by owner
     */
    function updateFeeRecipients(
        address _liquidityPool,
        address _oddao,
        address _protocol
    ) external onlyOwner {
        if (_liquidityPool == address(0) || _oddao == address(0) || _protocol == address(0)) {
            revert InvalidAddress();
        }

        feeRecipients = FeeRecipients({
            liquidityPool: _liquidityPool,
            oddao: _oddao,
            protocol: _protocol
        });
    }

    /**
     * @notice Update trading limits
     * @param _maxTradeSize Maximum trade size
     * @param _dailyVolumeLimit Daily volume limit
     * @param _maxSlippageBps Maximum slippage in basis points
     * @dev Can only be called by owner
     */
    function updateTradingLimits(
        uint256 _maxTradeSize,
        uint256 _dailyVolumeLimit,
        uint256 _maxSlippageBps
    ) external onlyOwner {
        if (_maxSlippageBps > MAX_SLIPPAGE_BPS) revert SlippageExceedsMaximum();

        maxTradeSize = _maxTradeSize;
        dailyVolumeLimit = _dailyVolumeLimit;
        maxSlippageBps = _maxSlippageBps;

        emit TradingLimitsUpdated(_maxTradeSize, _dailyVolumeLimit, _maxSlippageBps);
    }

    /**
     * @notice Trigger emergency stop for trading
     * @param reason Reason for emergency stop
     * @dev Can only be called by owner
     */
    function emergencyStopTrading(string calldata reason) external onlyOwner {
        emergencyStop = true;
        emit EmergencyStop(msg.sender, reason);
    }

    /**
     * @notice Resume trading after emergency stop
     * @dev Can only be called by owner
     */
    function resumeTrading() external onlyOwner {
        emergencyStop = false;
        emit TradingResumed(msg.sender);
    }

    /**
     * @notice Pause contract
     * @dev Can only be called by owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause contract
     * @dev Can only be called by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /**
     * @notice Get commitment for a trader and order hash
     * @param trader Trader address
     * @param orderHash Order hash
     * @return Commitment details
     */
    function getCommitment(
        address trader,
        bytes32 orderHash
    ) external view returns (Commitment memory) {
        return commitments[trader][orderHash];
    }

    /**
     * @notice Check if order is filled
     * @param orderHash Order hash
     * @return True if filled
     */
    function isOrderFilled(bytes32 orderHash) external view returns (bool) {
        return filledOrders[orderHash];
    }

    /**
     * @notice Get current nonce for a trader
     * @param trader Trader address
     * @return Current nonce
     */
    function getNonce(address trader) external view returns (uint256) {
        return nonces[trader];
    }

    /**
     * @notice Get trading statistics
     * @return volume Total trading volume
     * @return fees Total fees collected
     * @return dailyUsed Daily volume used
     * @return dailyLimit Daily volume limit
     */
    function getTradingStats()
        external
        view
        returns (
            uint256 volume,
            uint256 fees,
            uint256 dailyUsed,
            uint256 dailyLimit
        )
    {
        return (totalTradingVolume, totalFeesCollected, dailyVolumeUsed, dailyVolumeLimit);
    }

    /**
     * @notice Get fee recipient addresses
     * @return FeeRecipients struct
     */
    function getFeeRecipients() external view returns (FeeRecipients memory) {
        return feeRecipients;
    }

    /**
     * @notice Hash an order for EIP-712 signing
     * @param order Order to hash
     * @return Order hash
     */
    function hashOrder(Order calldata order) external view returns (bytes32) {
        return _hashTypedDataV4(_hashOrder(order));
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /**
     * @notice Hash order struct for EIP-712
     * @param order Order to hash
     * @return Struct hash
     */
    function _hashOrder(Order calldata order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.trader,
                order.isBuy,
                order.tokenIn,
                order.tokenOut,
                order.amountIn,
                order.amountOut,
                order.price,
                order.deadline,
                order.salt,
                order.matchingValidator,
                order.nonce
            )
        );
    }

    /**
     * @notice Verify that two orders match
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @dev Verifies price, amounts, and token pairs match
     */
    function _verifyOrdersMatch(
        Order calldata makerOrder,
        Order calldata takerOrder
    ) internal pure {
        // Verify opposite sides (maker sells = taker buys)
        if (makerOrder.isBuy == takerOrder.isBuy) revert OrdersDontMatch();

        // Verify token pairs match (maker's out = taker's in)
        if (makerOrder.tokenIn != takerOrder.tokenOut) revert OrdersDontMatch();
        if (makerOrder.tokenOut != takerOrder.tokenIn) revert OrdersDontMatch();

        // Verify amounts match (or taker amount ≤ maker amount for partial fills)
        if (takerOrder.amountIn > makerOrder.amountOut) revert OrdersDontMatch();
        if (takerOrder.amountOut > makerOrder.amountIn) revert OrdersDontMatch();

        // Verify price logic: maker's price must be better or equal to taker's price
        // For sell orders: maker's price ≤ taker's price
        // For buy orders: maker's price ≥ taker's price
        if (makerOrder.isBuy) {
            // Maker buying: maker's price must be ≥ taker's sell price
            if (makerOrder.price < takerOrder.price) revert OrdersDontMatch();
        } else {
            // Maker selling: maker's price must be ≤ taker's buy price
            if (makerOrder.price > takerOrder.price) revert OrdersDontMatch();
        }
    }

    /**
     * @notice Check token balances and allowances
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @dev Reverts if insufficient balance or allowance
     */
    function _checkBalancesAndAllowances(
        Order calldata makerOrder,
        Order calldata takerOrder
    ) internal view {
        // Check maker
        if (IERC20(makerOrder.tokenIn).balanceOf(makerOrder.trader) < makerOrder.amountIn) {
            revert InsufficientBalance(makerOrder.tokenIn, makerOrder.trader);
        }
        if (
            IERC20(makerOrder.tokenIn).allowance(makerOrder.trader, address(this)) <
            makerOrder.amountIn
        ) {
            revert InsufficientAllowance(makerOrder.tokenIn, makerOrder.trader);
        }

        // Check taker
        if (IERC20(takerOrder.tokenIn).balanceOf(takerOrder.trader) < takerOrder.amountIn) {
            revert InsufficientBalance(takerOrder.tokenIn, takerOrder.trader);
        }
        if (
            IERC20(takerOrder.tokenIn).allowance(takerOrder.trader, address(this)) <
            takerOrder.amountIn
        ) {
            revert InsufficientAllowance(takerOrder.tokenIn, takerOrder.trader);
        }
    }

    /**
     * @notice Execute atomic settlement of matched orders
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @param makerFee Fee charged to maker
     * @param takerFee Fee charged to taker
     * @dev Performs atomic token swaps between maker and taker
     */
    function _executeAtomicSettlement(
        Order calldata makerOrder,
        Order calldata takerOrder,
        uint256 makerFee,
        uint256 takerFee
    ) internal {
        // Transfer tokens from maker to taker (minus maker fee)
        IERC20(makerOrder.tokenIn).safeTransferFrom(
            makerOrder.trader,
            takerOrder.trader,
            makerOrder.amountIn
        );

        // Transfer tokens from taker to maker (minus taker fee)
        IERC20(takerOrder.tokenIn).safeTransferFrom(
            takerOrder.trader,
            makerOrder.trader,
            takerOrder.amountIn
        );

        // Collect maker fee
        if (makerFee > 0) {
            IERC20(makerOrder.tokenOut).safeTransferFrom(
                makerOrder.trader,
                address(this),
                makerFee
            );
        }

        // Collect taker fee
        if (takerFee > 0) {
            IERC20(takerOrder.tokenOut).safeTransferFrom(
                takerOrder.trader,
                address(this),
                takerFee
            );
        }
    }

    /**
     * @notice Distribute trading fees per token using pull pattern
     * @param makerFee Fee from maker (denominated in makerFeeToken)
     * @param takerFee Fee from taker (denominated in takerFeeToken)
     * @param makerFeeToken Token in which maker fee was collected
     * @param takerFeeToken Token in which taker fee was collected
     * @param matchingValidator Validator who matched the orders
     * @dev Distributes fees: 70% Liquidity Pool, 20% ODDAO, 10% Protocol.
     *      Fees are accrued per-token so claimFees() transfers the correct token.
     */
    function _distributeFees(
        uint256 makerFee,
        uint256 takerFee,
        address makerFeeToken,
        address takerFeeToken,
        address matchingValidator
    ) internal {
        uint256 totalFees = makerFee + takerFee;
        if (totalFees == 0) return;

        totalFeesCollected += totalFees;

        // Accrue maker fees per-token (pull pattern)
        if (makerFee > 0) {
            uint256 lp = (makerFee * LIQUIDITY_POOL_SHARE) / BASIS_POINTS_DIVISOR;
            uint256 od = (makerFee * ODDAO_SHARE) / BASIS_POINTS_DIVISOR;
            uint256 pr = (makerFee * PROTOCOL_SHARE) / BASIS_POINTS_DIVISOR;
            accruedFees[feeRecipients.liquidityPool][makerFeeToken] += lp;
            accruedFees[feeRecipients.oddao][makerFeeToken] += od;
            accruedFees[feeRecipients.protocol][makerFeeToken] += pr;
        }

        // Accrue taker fees per-token (pull pattern)
        if (takerFee > 0) {
            uint256 lp = (takerFee * LIQUIDITY_POOL_SHARE) / BASIS_POINTS_DIVISOR;
            uint256 od = (takerFee * ODDAO_SHARE) / BASIS_POINTS_DIVISOR;
            uint256 pr = (takerFee * PROTOCOL_SHARE) / BASIS_POINTS_DIVISOR;
            accruedFees[feeRecipients.liquidityPool][takerFeeToken] += lp;
            accruedFees[feeRecipients.oddao][takerFeeToken] += od;
            accruedFees[feeRecipients.protocol][takerFeeToken] += pr;
        }

        // Aggregate amounts for event (monitoring)
        uint256 liquidityPoolAmount = (totalFees * LIQUIDITY_POOL_SHARE) / BASIS_POINTS_DIVISOR;
        uint256 oddaoAmount = (totalFees * ODDAO_SHARE) / BASIS_POINTS_DIVISOR;
        uint256 protocolAmount = (totalFees * PROTOCOL_SHARE) / BASIS_POINTS_DIVISOR;

        emit FeesDistributed(
            matchingValidator,
            liquidityPoolAmount,
            oddaoAmount,
            protocolAmount,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }

    /**
     * @notice Claim accrued fees for a specific token
     * @dev Pull pattern: fee recipients call this to withdraw their accrued fees.
     *      Only the fee recipient can claim their own fees.
     * @param token ERC20 token to withdraw fees in
     */
    function claimFees(address token) external nonReentrant {
        uint256 amount = accruedFees[msg.sender][token];
        if (amount == 0) revert ZeroAmount();

        accruedFees[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit FeesClaimed(msg.sender, token, amount);
    }

    // ========================================================================
    // INTENT-BASED SETTLEMENT FUNCTIONS (Phase 3)
    // ========================================================================

    /**
     * @notice Intent collateral record
     * @param trader Trader address
     * @param solver Solver address
     * @param traderAmount Trader collateral amount
     * @param solverAmount Solver collateral amount
     * @param deadline Settlement deadline
     * @param locked Whether collateral is locked
     * @param settled Whether settlement is complete
     */
    struct IntentCollateral {
        address trader;
        address solver;
        uint256 traderAmount;
        uint256 solverAmount;
        uint256 deadline;
        bool locked;
        bool settled;
    }

    /// @notice Mapping of intentId => collateral record
    mapping(bytes32 => IntentCollateral) public intentCollateral;

    /**
     * @notice Emitted when intent collateral is locked
     * @param intentId Intent identifier
     * @param trader Trader address
     * @param solver Solver address
     * @param traderAmount Trader collateral
     * @param solverAmount Solver collateral
     */
    event IntentCollateralLocked(
        bytes32 indexed intentId,
        address indexed trader,
        address indexed solver,
        uint256 traderAmount,
        uint256 solverAmount
    );

    /**
     * @notice Emitted when intent is settled
     * @param intentId Intent identifier
     * @param trader Trader address
     * @param solver Solver address
     * @param traderAmount Amount from trader
     * @param solverAmount Amount from solver
     */
    event IntentSettled(
        bytes32 indexed intentId,
        address indexed trader,
        address indexed solver,
        uint256 traderAmount,
        uint256 solverAmount
    );

    /**
     * @notice Emitted when intent is cancelled
     * @param intentId Intent identifier
     * @param reason Cancellation reason
     */
    event IntentCancelled(bytes32 indexed intentId, string reason);

    /// @notice Thrown when collateral already locked
    error CollateralAlreadyLocked();

    /// @notice Thrown when collateral not locked
    error CollateralNotLocked();

    /// @notice Thrown when settlement already complete
    error AlreadySettled();

    /**
     * @notice Lock collateral for bilateral intent settlement
     * @param intentId Intent identifier (bytes32)
     * @param traderAmount Amount trader is providing
     * @param solverAmount Amount solver is providing
     * @param deadline Settlement deadline timestamp
     * @dev Both trader and solver must approve this contract before calling
     */
    function lockIntentCollateral(
        bytes32 intentId,
        uint256 traderAmount,
        uint256 solverAmount,
        uint256 deadline
    ) external whenNotPaused {
        if (intentCollateral[intentId].locked) revert CollateralAlreadyLocked();
        if (traderAmount == 0 || solverAmount == 0) revert ZeroAmount();
        if (deadline <= block.timestamp) revert OrderExpired();

        intentCollateral[intentId] = IntentCollateral({
            trader: msg.sender,
            solver: address(0), // Solver will be set during settlement
            traderAmount: traderAmount,
            solverAmount: solverAmount,
            deadline: deadline,
            locked: true,
            settled: false
        });

        emit IntentCollateralLocked(intentId, msg.sender, address(0), traderAmount, solverAmount);
    }

    /**
     * @notice Settle intent with bilateral swap
     * @param intentId Intent identifier
     * @param solver Solver address
     * @param tokenIn Token trader is selling
     * @param tokenOut Token trader is buying
     * @dev Executes atomic swap between trader and solver
     */
    function settleIntent(
        bytes32 intentId,
        address solver,
        address tokenIn,
        address tokenOut
    ) external nonReentrant whenNotPaused {
        if (emergencyStop) revert EmergencyStopActive();

        IntentCollateral storage collateral = intentCollateral[intentId];

        if (!collateral.locked) revert CollateralNotLocked();
        if (collateral.settled) revert AlreadySettled();
        if (block.timestamp > collateral.deadline) revert OrderExpired();

        // Set solver address
        collateral.solver = solver;

        // Transfer tokens from trader to solver
        IERC20(tokenIn).safeTransferFrom(
            collateral.trader,
            solver,
            collateral.traderAmount
        );

        // Transfer tokens from solver to trader
        IERC20(tokenOut).safeTransferFrom(
            solver,
            collateral.trader,
            collateral.solverAmount
        );

        // Mark as settled
        collateral.settled = true;

        emit IntentSettled(
            intentId,
            collateral.trader,
            solver,
            collateral.traderAmount,
            collateral.solverAmount
        );
    }

    /**
     * @notice Cancel intent and release collateral
     * @param intentId Intent identifier
     * @dev Can be called by trader if deadline passed
     */
    function cancelIntent(bytes32 intentId) external {
        IntentCollateral storage collateral = intentCollateral[intentId];

        if (!collateral.locked) revert CollateralNotLocked();
        if (collateral.settled) revert AlreadySettled();
        if (msg.sender != collateral.trader) revert InvalidSignature();

        // Reset collateral
        collateral.locked = false;

        emit IntentCancelled(intentId, "Cancelled by trader");
    }

    /**
     * @notice Get intent collateral details
     * @param intentId Intent identifier
     * @return Collateral record
     */
    function getIntentCollateral(bytes32 intentId) external view returns (IntentCollateral memory) {
        return intentCollateral[intentId];
    }
}
