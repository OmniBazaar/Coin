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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFeeSwapRouter} from "./interfaces/IFeeSwapRouter.sol";

/**
 * @title IOmniPrivacyBridge
 * @author OmniBazaar Team
 * @notice Subset of OmniPrivacyBridge used by UnifiedFeeVault
 */
interface IOmniPrivacyBridge {
    /**
     * @notice Convert pXOM back to XOM
     * @dev Burns pXOM from msg.sender, releases XOM to msg.sender.
     * @param amount Amount of pXOM to convert
     */
    function convertPXOMtoXOM(uint256 amount) external;
}

// ════════════════════════════════════════════════════════════════════════
//                          UNIFIED FEE VAULT
// ════════════════════════════════════════════════════════════════════════

/**
 * @title UnifiedFeeVault
 * @author OmniBazaar Team
 * @notice Aggregates protocol fees from all OmniBazaar markets and
 *         splits them according to the universal 70/20/10 schedule
 * @dev Single collection point for fees from MinimalEscrow,
 *      DEXSettlement, RWAAMM, RWAFeeCollector, OmniFeeRouter,
 *      OmniYieldFeeCollector, OmniPredictionRouter, and any future
 *      fee-generating contracts.
 *
 * Fee Distribution (per FIX_FEE_PAYMENTS.md):
 *   70% -> ODDAO Treasury (held for periodic bridging to Optimism)
 *   20% -> StakingRewardPool (on-chain, immediate transfer)
 *   10% -> Protocol Treasury (on-chain, governance-controlled)
 *
 * Design Decisions:
 * - UUPS upgradeable: allows fee logic updates without redeployment
 * - Pausable: emergency stop capability for fee processing
 * - Multi-token: accepts XOM, USDC, or any ERC20 fee payments
 * - Permissionless distribute(): anyone can trigger the fee split
 * - Role-gated bridge: only BRIDGE_ROLE can withdraw ODDAO share
 * - Deposit whitelist: only approved fee contracts can deposit
 * - Pull pattern: recipients claim fees; reverting recipients
 *   do not block distribution (M-03 audit fix)
 * - Timelock: recipient changes require 48h delay (M-02 audit fix)
 * - Rescue: admin can recover non-committed tokens (M-04 audit fix)
 *
 * Safety:
 * - ReentrancyGuard on all state-changing external functions
 * - CEI pattern (checks-effects-interactions) throughout
 * - Zero-amount guards on all transfers
 * - Overflow-safe math via Solidity 0.8.x defaults
 * - Ossification support for permanent finalization
 * - UUPS upgrade restricted to DEFAULT_ADMIN_ROLE
 */
contract UnifiedFeeVault is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // ════════════════════════════════════════════════════════════════════
    //                              ENUMS
    // ════════════════════════════════════════════════════════════════════

    /// @notice Strategy for bridging a token's ODDAO share
    /// @dev IN_KIND (0) bridges the original token as-is.
    ///      SWAP_TO_XOM (1) swaps the token to XOM before bridging.
    enum BridgeMode {
        IN_KIND,
        SWAP_TO_XOM
    }

    // ════════════════════════════════════════════════════════════════════
    //                           CONSTANTS
    // ════════════════════════════════════════════════════════════════════

    /// @notice ODDAO share: 70% of all collected fees
    uint256 public constant ODDAO_BPS = 7000;

    /// @notice Staking pool share: 20% of all collected fees
    uint256 public constant STAKING_BPS = 2000;

    /// @notice Protocol treasury share: 10% of all collected fees
    uint256 public constant PROTOCOL_BPS = 1000;

    /// @notice Basis points denominator for percentage math
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Role for addresses that can deposit fees
    bytes32 public constant DEPOSITOR_ROLE =
        keccak256("DEPOSITOR_ROLE");

    /// @notice Role for addresses that can bridge ODDAO funds
    bytes32 public constant BRIDGE_ROLE =
        keccak256("BRIDGE_ROLE");

    /// @notice Role for administrative operations
    bytes32 public constant ADMIN_ROLE =
        keccak256("ADMIN_ROLE");

    /// @notice Role for fee management operations
    bytes32 public constant FEE_MANAGER_ROLE =
        keccak256("FEE_MANAGER_ROLE");

    /// @notice Timelock delay for recipient changes (48 hours)
    /// @dev M-02 audit fix: prevents instant diversion of fee flow
    uint256 public constant RECIPIENT_CHANGE_DELAY = 48 hours;

    // ════════════════════════════════════════════════════════════════════
    //                         STATE VARIABLES
    // ════════════════════════════════════════════════════════════════════

    /// @notice StakingRewardPool address (receives 20%)
    address public stakingPool;

    /// @notice Protocol treasury address (receives 10%)
    address public protocolTreasury;

    /// @notice ODDAO share per token, awaiting bridge to Optimism
    /// @dev token address => accumulated amount
    mapping(address => uint256) public pendingBridge;

    /// @notice Lifetime fees distributed per token (for transparency)
    /// @dev token address => total distributed amount
    mapping(address => uint256) public totalDistributed;

    /// @notice Lifetime fees bridged per token (for transparency)
    /// @dev token address => total bridged amount
    mapping(address => uint256) public totalBridged;

    /// @notice Whether the contract has been permanently ossified
    /// @dev Once true, no further upgrades are possible
    bool private _ossified;

    /// @notice Pending recipient change awaiting timelock
    /// @dev Stores the proposed staking pool address
    address public pendingStakingPool;

    /// @notice Pending recipient change awaiting timelock
    /// @dev Stores the proposed protocol treasury address
    address public pendingProtocolTreasury;

    /// @notice Timestamp when pending recipient change can be applied
    /// @dev Zero means no pending change
    uint256 public recipientChangeTimestamp;

    /// @notice Accumulated claimable fees per recipient per token
    /// @dev M-03 audit fix: pull pattern for reverting recipients.
    ///      recipient address => token address => claimable amount
    mapping(address => mapping(address => uint256))
        public pendingClaims;

    // ── In-Kind / Swap-to-XOM Bridge Mode ────────────────────────

    /// @notice Per-token bridge strategy: in-kind (default) or swap
    /// @dev token address => BridgeMode enum value
    mapping(address => BridgeMode) public tokenBridgeMode;

    /// @notice IFeeSwapRouter adapter for token→XOM conversions
    address public swapRouter;

    /// @notice XOM token address (target of swap-to-XOM path)
    address public xomToken;

    /// @notice OmniPrivacyBridge address for pXOM→XOM conversions
    address public privacyBridge;

    /// @notice PrivateOmniCoin (pXOM) token address
    address public pxomToken;

    /// @notice Storage gap for future upgrades
    /// @dev Budget: 10 original + 5 new = 15 slots used. Gap = 35.
    ///      Reduce by N when adding N new state variables.
    uint256[35] private __gap;

    // ════════════════════════════════════════════════════════════════════
    //                             EVENTS
    // ════════════════════════════════════════════════════════════════════

    /// @notice Emitted when fees are deposited into the vault
    /// @param token ERC20 token address that was deposited
    /// @param amount Amount of tokens deposited
    /// @param depositor Address that deposited the fees
    event FeesDeposited(
        address indexed token,
        uint256 indexed amount,
        address indexed depositor
    );

    /// @notice Emitted when fees arrive via direct transfer (e.g., RWAAMM)
    /// @param token ERC20 token address that was notified
    /// @param amount Amount reported by the caller
    /// @param sender Address that sent the notification
    event FeesNotified(
        address indexed token,
        uint256 indexed amount,
        address indexed sender
    );

    /// @notice Emitted when accumulated fees are split 70/20/10
    /// @param token ERC20 token address that was distributed
    /// @param oddaoShare Amount allocated to ODDAO holding (70%)
    /// @param stakingShare Amount allocated to StakingRewardPool (20%)
    /// @param protocolShare Amount allocated to Protocol Treasury (10%)
    event FeesDistributed(
        address indexed token,
        uint256 indexed oddaoShare,
        uint256 indexed stakingShare,
        uint256 protocolShare
    );

    /// @notice Emitted when ODDAO funds are bridged to Optimism
    /// @param token ERC20 token address that was bridged
    /// @param amount Amount bridged
    /// @param recipient Bridge receiver address
    event FeesBridged(
        address indexed token,
        uint256 indexed amount,
        address indexed recipient
    );

    /// @notice Emitted when recipient addresses are updated
    /// @param stakingPool New staking pool address
    /// @param protocolTreasury New protocol treasury address
    event RecipientsUpdated(
        address indexed stakingPool,
        address indexed protocolTreasury
    );

    /// @notice Emitted when a recipient change is proposed
    /// @param stakingPool Proposed staking pool address
    /// @param protocolTreasury Proposed protocol treasury address
    /// @param effectiveTimestamp When the change can be applied
    event RecipientsChangeProposed(
        address indexed stakingPool,
        address indexed protocolTreasury,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when a pending recipient change is cancelled
    event RecipientsChangeCancelled();

    /// @notice Emitted when the contract is permanently ossified
    /// @param caller Address that triggered ossification
    event ContractOssified(address indexed caller);

    /// @notice Emitted when accidentally sent tokens are rescued
    /// @param token ERC20 token address that was rescued
    /// @param amount Amount rescued
    /// @param recipient Address receiving the rescued tokens
    event TokensRescued(
        address indexed token,
        uint256 indexed amount,
        address indexed recipient
    );

    /// @notice Emitted when a push transfer fails and is quarantined
    /// @param recipient Address that failed to receive
    /// @param token ERC20 token address
    /// @param amount Amount quarantined for pull withdrawal
    event TransferQuarantined(
        address indexed recipient,
        address indexed token,
        uint256 indexed amount
    );

    /// @notice Emitted when quarantined fees are claimed
    /// @param recipient Address claiming the fees
    /// @param token ERC20 token address
    /// @param amount Amount claimed
    event PendingClaimWithdrawn(
        address indexed recipient,
        address indexed token,
        uint256 indexed amount
    );

    /// @notice Emitted when fees are swapped to XOM and bridged
    /// @param token Original fee token that was swapped
    /// @param tokenAmount Amount of original token swapped
    /// @param xomReceived Amount of XOM received from swap
    /// @param recipient Bridge receiver address
    event FeesSwappedAndBridged(
        address indexed token,
        uint256 indexed tokenAmount,
        uint256 xomReceived,
        address indexed recipient
    );

    /// @notice Emitted when pXOM is converted to XOM via privacy bridge
    /// @param amount Amount of pXOM converted
    /// @param xomReceived Amount of XOM received
    event PXOMConverted(
        uint256 indexed amount,
        uint256 indexed xomReceived
    );

    /// @notice Emitted when a token's bridge mode is changed
    /// @param token Token whose mode was updated
    /// @param mode New bridge mode (0=IN_KIND, 1=SWAP_TO_XOM)
    event TokenBridgeModeSet(
        address indexed token,
        BridgeMode indexed mode
    );

    /// @notice Emitted when the swap router is updated
    /// @param newRouter New IFeeSwapRouter adapter address
    event SwapRouterUpdated(address indexed newRouter);

    /// @notice Emitted when the privacy bridge config is updated
    /// @param bridge New OmniPrivacyBridge address
    /// @param pxom New PrivateOmniCoin address
    event PrivacyBridgeUpdated(
        address indexed bridge,
        address indexed pxom
    );

    /// @notice Emitted when the XOM token address is set
    /// @param xom New XOM token address
    event XOMTokenUpdated(address indexed xom);

    // ════════════════════════════════════════════════════════════════════
    //                          CUSTOM ERRORS
    // ════════════════════════════════════════════════════════════════════

    /// @notice Thrown when a zero address is provided
    error ZeroAddress();

    /// @notice Thrown when a zero amount is provided
    error ZeroAmount();

    /// @notice Thrown when there is nothing to distribute
    error NothingToDistribute();

    /// @notice Thrown when bridge amount exceeds pending balance
    /// @param requested Amount requested for bridging
    /// @param available Amount available for bridging
    error InsufficientPendingBalance(
        uint256 requested,
        uint256 available
    );

    /// @notice Thrown when the contract is ossified and upgrades blocked
    error ContractIsOssified();

    /// @notice Thrown when timelock delay has not elapsed
    error TimelockNotElapsed();

    /// @notice Thrown when no pending recipient change exists
    error NoPendingChange();

    /// @notice Thrown when there is nothing to claim
    error NothingToClaim();

    /// @notice Thrown when rescue would drain committed funds
    /// @param token Token address involved
    /// @param committed Amount committed (pendingBridge)
    error CannotRescueCommittedFunds(
        address token,
        uint256 committed
    );

    /// @notice Thrown when new implementation has no deployed code
    error InvalidImplementation();

    /// @notice Thrown when swapRouter is not configured
    error SwapRouterNotSet();

    /// @notice Thrown when xomToken is not configured
    error XOMTokenNotSet();

    /// @notice Thrown when swap output is below the minimum
    /// @param received Actual XOM received
    /// @param minimum Required minimum
    error InsufficientSwapOutput(
        uint256 received,
        uint256 minimum
    );

    /// @notice Thrown when pXOM→XOM conversion fails
    error PXOMConversionFailed();

    /// @notice Thrown when privacy bridge is not configured
    error PrivacyBridgeNotSet();

    // ════════════════════════════════════════════════════════════════════
    //                      CONSTRUCTOR & INITIALIZER
    // ════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the UnifiedFeeVault proxy
     * @dev Called once during proxy deployment. Sets up roles and
     *      recipient addresses for the 70/20/10 split.
     *      Fee distribution ratios:
     *        ODDAO:    70% (7000 BPS) -- held for bridging
     *        Staking:  20% (2000 BPS) -- immediate transfer
     *        Protocol: 10% (1000 BPS) -- immediate transfer
     * @param admin Address granted DEFAULT_ADMIN_ROLE and ADMIN_ROLE
     * @param _stakingPool StakingRewardPool contract address (20%)
     * @param _protocolTreasury Protocol treasury address (10%)
     */
    function initialize(
        address admin,
        address _stakingPool,
        address _protocolTreasury
    ) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (_stakingPool == address(0)) revert ZeroAddress();
        if (_protocolTreasury == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(BRIDGE_ROLE, admin);

        stakingPool = _stakingPool;
        protocolTreasury = _protocolTreasury;
    }

    // ════════════════════════════════════════════════════════════════════
    //                        EXTERNAL FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit fees into the vault from an approved fee contract
     * @dev Only addresses with DEPOSITOR_ROLE can call this. The caller
     *      must have approved this contract for the deposit amount.
     *      Emits the actual received amount to handle fee-on-transfer
     *      tokens correctly.
     * @param token ERC20 token address to deposit
     * @param amount Amount of tokens to deposit
     */
    function deposit(
        address token,
        uint256 amount
    ) external onlyRole(DEPOSITOR_ROLE) nonReentrant whenNotPaused {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 balBefore =
            IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(
            msg.sender, address(this), amount
        );
        uint256 actualReceived =
            IERC20(token).balanceOf(address(this)) - balBefore;

        emit FeesDeposited(token, actualReceived, msg.sender);
    }

    /**
     * @notice Notify the vault that fees arrived via direct transfer
     * @dev M-01 audit fix: RWAAMM sends fees via direct safeTransfer
     *      bypassing deposit(). This function emits FeesNotified so
     *      off-chain indexers can track all fee inflows. Callable
     *      by anyone; the distribute() function uses balanceOf()
     *      regardless, so this is purely for audit trail purposes.
     * @param token ERC20 token address that was transferred
     * @param amount Amount that was transferred
     */
    function notifyDeposit(
        address token,
        uint256 amount
    ) external {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        emit FeesNotified(token, amount, msg.sender);
    }

    /**
     * @notice Split accumulated fees for a token using 70/20/10
     * @dev Permissionless: anyone can trigger distribution. This
     *      encourages timely fee processing without relying on
     *      a centralized caller.
     *
     *      The 70% ODDAO share stays in the vault, tracked in
     *      pendingBridge[token], until bridgeToTreasury() is called.
     *
     *      The 20% and 10% shares are pushed to stakingPool and
     *      protocolTreasury respectively. If a push fails (recipient
     *      reverts), the share is quarantined in pendingClaims for
     *      later pull withdrawal via claimPending() (M-03 audit fix).
     *
     *      Fee Distribution Ratios:
     *        ODDAO:    70% (7000 BPS)
     *        Staking:  20% (2000 BPS)
     *        Protocol: 10% (1000 BPS, remainder to avoid dust loss)
     * @param token ERC20 token address to distribute
     */
    function distribute(
        address token
    ) external nonReentrant whenNotPaused {
        if (token == address(0)) revert ZeroAddress();

        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 distributable = balance - pendingBridge[token];

        if (distributable == 0) revert NothingToDistribute();

        // Calculate shares
        uint256 oddaoShare =
            (distributable * ODDAO_BPS) / BPS_DENOMINATOR;
        uint256 stakingShare =
            (distributable * STAKING_BPS) / BPS_DENOMINATOR;
        // Protocol gets remainder to avoid rounding dust loss
        uint256 protocolShare =
            distributable - oddaoShare - stakingShare;

        // Effects: update state before transfers (CEI)
        pendingBridge[token] += oddaoShare;
        totalDistributed[token] += distributable;

        // Interactions: transfer staking and protocol shares.
        // M-03 audit fix: use try/catch to quarantine failed pushes
        // so one reverting recipient does not block distribution.
        if (stakingShare > 0) {
            _safePushOrQuarantine(
                token, stakingPool, stakingShare
            );
        }
        if (protocolShare > 0) {
            _safePushOrQuarantine(
                token, protocolTreasury, protocolShare
            );
        }

        emit FeesDistributed(
            token, oddaoShare, stakingShare, protocolShare
        );
    }

    /**
     * @notice Claim quarantined fees that failed to push
     * @dev M-03 audit fix: pull pattern for reverting recipients.
     *      Only the intended recipient can claim their quarantined
     *      fees.
     * @param token ERC20 token address to claim
     */
    function claimPending(
        address token
    ) external nonReentrant {
        uint256 amount = pendingClaims[msg.sender][token];
        if (amount == 0) revert NothingToClaim();

        pendingClaims[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit PendingClaimWithdrawn(msg.sender, token, amount);
    }

    // ════════════════════════════════════════════════════════════════════
    //                   MARKETPLACE FEE SETTLEMENT
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit and distribute a marketplace transaction fee
     * @dev Calculates the 1% marketplace fee split on-chain:
     *      - 0.50% transaction fee: 70% ODDAO, 20% validator, 10%
     *        staking
     *      - 0.25% referral fee: 70% referrer, 20% L2 referrer, 10%
     *        ODDAO
     *      - 0.25% listing fee: 70% listing node, 20% selling node,
     *        10% ODDAO
     *
     *      Caller must have DEPOSITOR_ROLE and have approved this
     *      contract for the fee amount (1% of saleAmount in XOM).
     *
     * @param token XOM token address (fee currency)
     * @param saleAmount Total sale amount (fee calculated as 1%)
     * @param validator Validator processing the sale
     * @param referrer Referrer who referred the seller (zero if none)
     * @param referrerL2 Second-level referrer (zero if none)
     * @param listingNode Node where listing was created
     * @param sellingNode Node where buyer is shopping
     */
    function depositMarketplaceFee(
        address token,
        uint256 saleAmount,
        address validator,
        address referrer,
        address referrerL2,
        address listingNode,
        address sellingNode
    ) external onlyRole(DEPOSITOR_ROLE) nonReentrant whenNotPaused {
        if (token == address(0)) revert ZeroAddress();
        if (saleAmount == 0) revert ZeroAmount();

        // Total fee = 1% of sale amount
        uint256 totalFee = saleAmount / 100;
        if (totalFee == 0) revert ZeroAmount();

        // Transfer total fee from caller
        IERC20(token).safeTransferFrom(
            msg.sender, address(this), totalFee
        );

        // Split 1: Transaction fee (0.50% = half of total fee)
        uint256 txFee = totalFee / 2;
        uint256 txOddao = (txFee * 7000) / 10000; // 70% ODDAO
        uint256 txValidator = (txFee * 2000) / 10000; // 20% validator
        uint256 txStaking = txFee - txOddao - txValidator; // 10%

        pendingBridge[token] += txOddao;
        pendingClaims[validator][token] += txValidator;
        _safePushOrQuarantine(token, stakingPool, txStaking);

        // Split 2: Referral fee (0.25% = quarter of total fee)
        uint256 refFee = totalFee / 4;
        uint256 refPrimary = (refFee * 7000) / 10000; // 70% referrer
        uint256 refSecondary = (refFee * 2000) / 10000; // 20% L2
        uint256 refOddao = refFee - refPrimary - refSecondary; // 10%

        if (referrer != address(0)) {
            pendingClaims[referrer][token] += refPrimary;
        } else {
            pendingBridge[token] += refPrimary;
        }
        if (referrerL2 != address(0)) {
            pendingClaims[referrerL2][token] += refSecondary;
        } else {
            pendingBridge[token] += refSecondary;
        }
        pendingBridge[token] += refOddao;

        // Split 3: Listing fee (0.25% = quarter of total fee)
        uint256 listFee = totalFee - txFee - refFee; // remainder
        uint256 listNode = (listFee * 7000) / 10000; // 70%
        uint256 sellNode = (listFee * 2000) / 10000; // 20%
        uint256 listOddao = listFee - listNode - sellNode; // 10%

        if (listingNode != address(0)) {
            pendingClaims[listingNode][token] += listNode;
        } else {
            pendingBridge[token] += listNode;
        }
        if (sellingNode != address(0)) {
            pendingClaims[sellingNode][token] += sellNode;
        } else {
            pendingBridge[token] += sellNode;
        }
        pendingBridge[token] += listOddao;

        totalDistributed[token] += totalFee;

        emit FeesDeposited(token, totalFee, msg.sender);
    }

    /**
     * @notice Deposit and distribute an arbitration fee
     * @dev Arbitration fee = 5% of disputed amount. Split:
     *      70% arbitrator panel, 20% validator, 10% ODDAO.
     *      Caller must have DEPOSITOR_ROLE and approved the fee.
     * @param token XOM token address
     * @param disputeAmount Amount in dispute
     * @param arbitrator Arbitrator receiving primary share
     * @param validator Validator processing the dispute
     */
    function depositArbitrationFee(
        address token,
        uint256 disputeAmount,
        address arbitrator,
        address validator
    ) external onlyRole(DEPOSITOR_ROLE) nonReentrant whenNotPaused {
        if (token == address(0)) revert ZeroAddress();
        if (disputeAmount == 0) revert ZeroAmount();

        uint256 totalFee = (disputeAmount * 500) / 10000; // 5%
        if (totalFee == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(
            msg.sender, address(this), totalFee
        );

        uint256 arbShare = (totalFee * 7000) / 10000; // 70%
        uint256 valShare = (totalFee * 2000) / 10000; // 20%
        uint256 oddaoShare = totalFee - arbShare - valShare; // 10%

        pendingClaims[arbitrator][token] += arbShare;
        pendingClaims[validator][token] += valShare;
        pendingBridge[token] += oddaoShare;

        totalDistributed[token] += totalFee;

        emit FeesDeposited(token, totalFee, msg.sender);
    }

    // ════════════════════════════════════════════════════════════════════
    //                     FEE BREAKDOWN VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate marketplace fee breakdown for a sale amount
     * @param saleAmount Total sale amount
     * @return totalFee Total 1% fee
     * @return txFee Transaction fee portion (0.50%)
     * @return refFee Referral fee portion (0.25%)
     * @return listFee Listing fee portion (0.25%)
     */
    function getMarketplaceFeeBreakdown(
        uint256 saleAmount
    )
        external
        pure
        returns (
            uint256 totalFee,
            uint256 txFee,
            uint256 refFee,
            uint256 listFee
        )
    {
        totalFee = saleAmount / 100;
        txFee = totalFee / 2;
        refFee = totalFee / 4;
        listFee = totalFee - txFee - refFee;
    }

    /**
     * @notice Calculate arbitration fee breakdown
     * @param disputeAmount Disputed amount
     * @return totalFee Total 5% fee
     * @return arbitratorShare 70% to arbitrator
     * @return validatorShare 20% to validator
     * @return oddaoShare 10% to ODDAO
     */
    function getArbitrationFeeBreakdown(
        uint256 disputeAmount
    )
        external
        pure
        returns (
            uint256 totalFee,
            uint256 arbitratorShare,
            uint256 validatorShare,
            uint256 oddaoShare
        )
    {
        totalFee = (disputeAmount * 500) / 10000;
        arbitratorShare = (totalFee * 7000) / 10000;
        validatorShare = (totalFee * 2000) / 10000;
        oddaoShare = totalFee - arbitratorShare - validatorShare;
    }

    /**
     * @notice Bridge accumulated ODDAO share to Optimism treasury
     * @dev Only BRIDGE_ROLE can call. Transfers tokens to a bridge
     *      receiver address (bridge contract or direct recipient).
     *      The bridge operator is responsible for completing the
     *      cross-chain transfer.
     * @param token ERC20 token to bridge
     * @param amount Amount to bridge (must be <= pendingBridge)
     * @param bridgeReceiver Address to send tokens to
     */
    function bridgeToTreasury(
        address token,
        uint256 amount,
        address bridgeReceiver
    ) external onlyRole(BRIDGE_ROLE) nonReentrant whenNotPaused {
        if (token == address(0)) revert ZeroAddress();
        if (bridgeReceiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 pending = pendingBridge[token];
        if (amount > pending) {
            revert InsufficientPendingBalance(amount, pending);
        }

        // Effects first (CEI)
        pendingBridge[token] -= amount;
        totalBridged[token] += amount;

        // Interaction
        IERC20(token).safeTransfer(bridgeReceiver, amount);

        emit FeesBridged(token, amount, bridgeReceiver);
    }

    // ════════════════════════════════════════════════════════════════════
    //                         ADMIN FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Propose new staking pool and protocol treasury addresses
     * @dev M-02 audit fix: changes are not applied immediately.
     *      After RECIPIENT_CHANGE_DELAY (48 hours) elapses, call
     *      applyRecipients() to finalize the change. This prevents
     *      instant diversion of the 30% fee flow from a compromised
     *      ADMIN_ROLE key.
     * @param _stakingPool Proposed StakingRewardPool address
     * @param _protocolTreasury Proposed protocol treasury address
     */
    function proposeRecipients(
        address _stakingPool,
        address _protocolTreasury
    ) external onlyRole(ADMIN_ROLE) {
        if (_stakingPool == address(0)) revert ZeroAddress();
        if (_protocolTreasury == address(0)) revert ZeroAddress();

        pendingStakingPool = _stakingPool;
        pendingProtocolTreasury = _protocolTreasury;
        /* solhint-disable not-rely-on-time */
        recipientChangeTimestamp =
            block.timestamp + RECIPIENT_CHANGE_DELAY;
        /* solhint-enable not-rely-on-time */

        emit RecipientsChangeProposed(
            _stakingPool,
            _protocolTreasury,
            recipientChangeTimestamp
        );
    }

    /**
     * @notice Apply the pending recipient change after timelock
     * @dev Reverts if timelock has not elapsed or no pending change
     *      exists. Only ADMIN_ROLE can execute.
     */
    function applyRecipients()
        external
        onlyRole(ADMIN_ROLE)
    {
        if (recipientChangeTimestamp == 0) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < recipientChangeTimestamp) {
            revert TimelockNotElapsed();
        }

        stakingPool = pendingStakingPool;
        protocolTreasury = pendingProtocolTreasury;

        // Clear pending state
        pendingStakingPool = address(0);
        pendingProtocolTreasury = address(0);
        recipientChangeTimestamp = 0;

        emit RecipientsUpdated(stakingPool, protocolTreasury);
    }

    /**
     * @notice Cancel a pending recipient change
     * @dev Can be called at any time before applyRecipients().
     */
    function cancelRecipientsChange()
        external
        onlyRole(ADMIN_ROLE)
    {
        if (recipientChangeTimestamp == 0) {
            revert NoPendingChange();
        }

        pendingStakingPool = address(0);
        pendingProtocolTreasury = address(0);
        recipientChangeTimestamp = 0;

        emit RecipientsChangeCancelled();
    }

    /**
     * @notice Rescue accidentally sent tokens from the vault
     * @dev M-04 audit fix: allows recovery of non-fee tokens or
     *      excess tokens not committed to pendingBridge. Cannot
     *      rescue tokens that are committed for ODDAO bridging.
     *      Only DEFAULT_ADMIN_ROLE can call.
     * @param token ERC20 token address to rescue
     * @param amount Amount to rescue
     * @param recipient Address to send rescued tokens to
     */
    function rescueToken(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // Prevent rescuing tokens committed for ODDAO bridging
        uint256 vaultBalance =
            IERC20(token).balanceOf(address(this));
        uint256 committed = pendingBridge[token];
        if (vaultBalance < committed + amount) {
            revert CannotRescueCommittedFunds(token, committed);
        }

        IERC20(token).safeTransfer(recipient, amount);
        emit TokensRescued(token, amount, recipient);
    }

    /**
     * @notice Pause the contract in case of emergency
     * @dev Blocks deposit, distribute, and bridgeToTreasury.
     *      Only ADMIN_ROLE can pause.
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract after emergency resolution
     * @dev Only ADMIN_ROLE can unpause.
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Permanently freeze the contract against upgrades
     * @dev Cannot be undone. Use only when the fee vault logic
     *      has been battle-tested and no further changes are needed.
     *      Only DEFAULT_ADMIN_ROLE can ossify.
     */
    function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _ossified = true;
        emit ContractOssified(msg.sender);
    }

    // ── In-Kind / Swap-to-XOM Admin Configuration ────────────────

    /**
     * @notice Set the bridge mode for a specific token
     * @dev IN_KIND (0) bridges the token as-is (default).
     *      SWAP_TO_XOM (1) swaps to XOM before bridging.
     * @param token ERC20 token whose mode to set
     * @param mode Desired bridge mode
     */
    function setTokenBridgeMode(
        address token,
        BridgeMode mode
    ) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();

        tokenBridgeMode[token] = mode;
        emit TokenBridgeModeSet(token, mode);
    }

    /**
     * @notice Set the IFeeSwapRouter adapter used for token→XOM swaps
     * @param _swapRouter FeeSwapAdapter contract address
     */
    function setSwapRouter(
        address _swapRouter
    ) external onlyRole(ADMIN_ROLE) {
        if (_swapRouter == address(0)) revert ZeroAddress();

        swapRouter = _swapRouter;
        emit SwapRouterUpdated(_swapRouter);
    }

    /**
     * @notice Set the XOM token address (swap target)
     * @param _xomToken OmniCoin ERC20 address
     */
    function setXomToken(
        address _xomToken
    ) external onlyRole(ADMIN_ROLE) {
        if (_xomToken == address(0)) revert ZeroAddress();

        xomToken = _xomToken;
        emit XOMTokenUpdated(_xomToken);
    }

    /**
     * @notice Set the OmniPrivacyBridge and pXOM token addresses
     * @param _bridge OmniPrivacyBridge contract address
     * @param _pxom PrivateOmniCoin (pXOM) ERC20 address
     */
    function setPrivacyBridge(
        address _bridge,
        address _pxom
    ) external onlyRole(ADMIN_ROLE) {
        if (_bridge == address(0)) revert ZeroAddress();
        if (_pxom == address(0)) revert ZeroAddress();

        privacyBridge = _bridge;
        pxomToken = _pxom;
        emit PrivacyBridgeUpdated(_bridge, _pxom);
    }

    // ── Swap-and-Bridge Functions ────────────────────────────────

    /**
     * @notice Swap a fee token to XOM and bridge to ODDAO treasury
     * @dev Deducts from pendingBridge[token], swaps via the
     *      IFeeSwapRouter adapter, and transfers XOM to receiver.
     *      Uses balance-before/after to verify received amount.
     * @param token ERC20 fee token to swap
     * @param amount Amount of token to swap (must be <= pending)
     * @param minXOMOut Minimum XOM output (slippage protection)
     * @param bridgeReceiver Address to receive the XOM
     */
    function swapAndBridge(
        address token,
        uint256 amount,
        uint256 minXOMOut,
        address bridgeReceiver
    )
        external
        onlyRole(BRIDGE_ROLE)
        nonReentrant
        whenNotPaused
    {
        _validateSwapBridge(token, bridgeReceiver, amount);

        // Effects (CEI)
        pendingBridge[token] -= amount;
        totalBridged[token] += amount;

        // Interactions: approve adapter, execute swap
        IERC20(token).forceApprove(swapRouter, amount);

        uint256 xomBefore =
            IERC20(xomToken).balanceOf(address(this));

        IFeeSwapRouter(swapRouter).swapExactInput(
            token, xomToken, amount, minXOMOut, address(this)
        );

        uint256 xomReceived =
            IERC20(xomToken).balanceOf(address(this)) - xomBefore;

        if (xomReceived < minXOMOut) {
            revert InsufficientSwapOutput(xomReceived, minXOMOut);
        }

        // Transfer XOM to bridge receiver
        IERC20(xomToken).safeTransfer(bridgeReceiver, xomReceived);

        emit FeesSwappedAndBridged(
            token, amount, xomReceived, bridgeReceiver
        );
    }

    /**
     * @notice Convert accumulated pXOM fees to XOM and bridge
     * @dev Burns pXOM via OmniPrivacyBridge.convertPXOMtoXOM(),
     *      which releases XOM to this contract, then transfers
     *      the received XOM to bridgeReceiver.
     * @param amount Amount of pXOM to convert (must be <= pending)
     * @param bridgeReceiver Address to receive the XOM
     */
    function convertPXOMAndBridge(
        uint256 amount,
        address bridgeReceiver
    )
        external
        onlyRole(BRIDGE_ROLE)
        nonReentrant
        whenNotPaused
    {
        _validatePXOMBridge(bridgeReceiver, amount);

        // Effects (CEI)
        pendingBridge[pxomToken] -= amount;
        totalBridged[pxomToken] += amount;

        // Interactions: approve bridge, convert pXOM→XOM
        IERC20(pxomToken).forceApprove(privacyBridge, amount);

        uint256 xomBefore =
            IERC20(xomToken).balanceOf(address(this));

        IOmniPrivacyBridge(privacyBridge).convertPXOMtoXOM(amount);

        uint256 xomReceived =
            IERC20(xomToken).balanceOf(address(this)) - xomBefore;

        if (xomReceived == 0) revert PXOMConversionFailed();

        // Transfer received XOM to bridge receiver
        IERC20(xomToken).safeTransfer(bridgeReceiver, xomReceived);

        emit PXOMConverted(amount, xomReceived);
        emit FeesBridged(xomToken, xomReceived, bridgeReceiver);
    }

    // ════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Get the undistributed balance for a token
     * @dev This is the amount available for the next distribute() call.
     *      Equals the vault's token balance minus the ODDAO share
     *      that has already been split but not yet bridged.
     * @param token ERC20 token address to query
     * @return Undistributed token balance
     */
    function undistributed(
        address token
    ) external view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 pending = pendingBridge[token];
        if (balance < pending) return 0;
        return balance - pending;
    }

    /**
     * @notice Get the pending ODDAO bridge amount for a token
     * @param token ERC20 token address to query
     * @return Amount awaiting bridging to Optimism
     */
    function pendingForBridge(
        address token
    ) external view returns (uint256) {
        return pendingBridge[token];
    }

    /**
     * @notice Check whether the contract has been ossified
     * @return True if no further upgrades are possible
     */
    function isOssified() external view returns (bool) {
        return _ossified;
    }

    /**
     * @notice Get the claimable amount for a recipient/token pair
     * @dev Used by recipients whose push transfer was quarantined
     * @param recipient Address to check
     * @param token ERC20 token address to check
     * @return Amount available for claim via claimPending()
     */
    function getClaimable(
        address recipient,
        address token
    ) external view returns (uint256) {
        return pendingClaims[recipient][token];
    }

    // ════════════════════════════════════════════════════════════════════
    //                       INTERNAL FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Attempt to push tokens to a recipient; quarantine on fail
     * @dev M-03 audit fix: wraps safeTransfer in a low-level call
     *      so that a reverting recipient does not block the entire
     *      distribute() transaction. On failure, the amount is
     *      credited to pendingClaims for later pull withdrawal.
     * @param token ERC20 token to transfer
     * @param recipient Target address
     * @param amount Amount to transfer
     */
    function _safePushOrQuarantine(
        address token,
        address recipient,
        uint256 amount
    ) internal {
        // Use low-level call wrapping safeTransfer to catch reverts
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = address(token).call(
            abi.encodeWithSelector(
                IERC20.transfer.selector,
                recipient,
                amount
            )
        );

        if (!success) {
            // solhint-disable-next-line reentrancy
            pendingClaims[recipient][token] += amount;
            emit TransferQuarantined(recipient, token, amount);
        }
    }

    /**
     * @notice Authorize a UUPS upgrade
     * @dev Restricted to DEFAULT_ADMIN_ROLE and blocked when ossified.
     *      Validates that the new implementation has deployed code
     *      to prevent bricking the proxy (I-04 audit fix).
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
        if (newImplementation.code.length == 0) {
            revert InvalidImplementation();
        }
    }

    /**
     * @notice Validate inputs for swapAndBridge
     * @dev Extracted to reduce cyclomatic complexity of swapAndBridge.
     *      Checks zero-address, zero-amount, router/xom config, and
     *      that the requested amount does not exceed pendingBridge.
     * @param token ERC20 fee token address
     * @param bridgeReceiver Destination address for XOM
     * @param amount Amount of token to swap
     */
    function _validateSwapBridge(
        address token,
        address bridgeReceiver,
        uint256 amount
    ) internal view {
        if (token == address(0)) revert ZeroAddress();
        if (bridgeReceiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (swapRouter == address(0)) revert SwapRouterNotSet();
        if (xomToken == address(0)) revert XOMTokenNotSet();

        uint256 pending = pendingBridge[token];
        if (amount > pending) {
            revert InsufficientPendingBalance(amount, pending);
        }
    }

    /**
     * @notice Validate inputs for convertPXOMAndBridge
     * @dev Extracted to reduce cyclomatic complexity of
     *      convertPXOMAndBridge. Checks zero-address, zero-amount,
     *      bridge/pxom/xom config, and pending balance.
     * @param bridgeReceiver Destination address for XOM
     * @param amount Amount of pXOM to convert
     */
    function _validatePXOMBridge(
        address bridgeReceiver,
        uint256 amount
    ) internal view {
        if (bridgeReceiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (privacyBridge == address(0)) revert PrivacyBridgeNotSet();
        if (pxomToken == address(0)) revert PrivacyBridgeNotSet();
        if (xomToken == address(0)) revert XOMTokenNotSet();

        uint256 pending = pendingBridge[pxomToken];
        if (amount > pending) {
            revert InsufficientPendingBalance(amount, pending);
        }
    }
}
