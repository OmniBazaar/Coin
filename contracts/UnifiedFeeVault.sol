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
import {ERC2771ContextUpgradeable} from
    "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {ContextUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

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
 *
 * @custom:security-contact security@omnibazaar.com
 * @custom:deployment-note ADMIN_ROLE and DEFAULT_ADMIN_ROLE
 *      should be transferred to a multi-sig (e.g., Gnosis Safe)
 *      before mainnet launch to mitigate centralization risk.
 *      Single-key admin control is acceptable only during testnet
 *      and initial deployment phases.
 * @custom:upgrade-note For future upgrades, consider migrating
 *      DEFAULT_ADMIN_ROLE management to
 *      AccessControlDefaultAdminRulesUpgradeable to enforce
 *      two-step admin transfers with a built-in timelock.
 */
contract UnifiedFeeVault is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ERC2771ContextUpgradeable
{
    using SafeERC20 for IERC20;

    /// @dev AUDIT ACCEPTED (Round 6): Fee-on-transfer and rebasing tokens are not
    ///      supported. OmniCoin (XOM) is the primary token and does not have these
    ///      features. Only vetted tokens (XOM, USDC, WBTC, WETH) are whitelisted
    ///      for use in the platform. This is documented in deployment guides.

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

    /// @notice Timelock delay for configuration changes (48 hours)
    /// @dev Used for swap router and privacy bridge timelocks
    uint256 public constant RECIPIENT_CHANGE_DELAY = 48 hours;

    /// @notice Minimum sale amount for marketplace fees (M-04 Round 6)
    /// @dev Prevents rounding loss on extremely small sales.
    ///      10000 ensures totalFee >= 100, providing adequate
    ///      precision for all 70/20/10 sub-splits.
    uint256 public constant MIN_SALE_AMOUNT = 10_000;

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

    /// @custom:deprecated Kept for UUPS storage layout compatibility.
    ///     Was: address public pendingStakingPool (packed in slot 5
    ///     with _ossified). Removed in Pioneer Phase (no recipient
    ///     timelock). Must remain to preserve slot assignments of all
    ///     subsequent state variables.
    /// @custom:oz-renamed-from pendingStakingPool
    // solhint-disable-next-line var-name-mixedcase
    address private __deprecated_pendingStakingPool;

    /// @custom:deprecated Kept for UUPS storage layout compatibility.
    ///     Was: address public pendingProtocolTreasury (slot 6).
    /// @custom:oz-renamed-from pendingProtocolTreasury
    // solhint-disable-next-line var-name-mixedcase
    address private __deprecated_pendingProtocolTreasury;

    /// @custom:deprecated Kept for UUPS storage layout compatibility.
    ///     Was: uint256 public recipientChangeTimestamp (slot 7).
    /// @custom:oz-renamed-from recipientChangeTimestamp
    // solhint-disable-next-line var-name-mixedcase
    uint256 private __deprecated_recipientChangeTimestamp;

    /// @notice Accumulated claimable fees per recipient per token
    /// @dev M-03 audit fix: pull pattern for reverting recipients.
    ///      recipient address => token address => claimable amount
    mapping(address => mapping(address => uint256))
        public pendingClaims;

    /// @notice Total pending claims per token across all recipients
    /// @dev C-01 audit fix: tracks sum of all pendingClaims for
    ///      each token so rescueToken() and distribute() can
    ///      accurately calculate committed funds.
    ///      token address => total claimable amount
    mapping(address => uint256) public totalPendingClaims;

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

    // ── Timelock: Swap Router ─────────────────────────────────────

    /// @notice Proposed swap router awaiting timelock expiry
    /// @dev H-03 audit fix: timelock on critical configuration
    address public pendingSwapRouter;

    /// @notice Timestamp when proposed swap router can be applied
    /// @dev Zero means no pending change
    uint256 public swapRouterChangeTimestamp;

    // ── Timelock: Privacy Bridge ──────────────────────────────────

    /// @notice Proposed privacy bridge awaiting timelock expiry
    /// @dev H-03 audit fix: timelock on critical configuration
    address public pendingPrivacyBridgeAddr;

    /// @notice Proposed pXOM token for pending privacy bridge change
    /// @dev H-03 audit fix: paired with pendingPrivacyBridgeAddr
    address public pendingPXOMToken;

    /// @notice Timestamp when proposed privacy bridge can be applied
    /// @dev Zero means no pending change
    uint256 public privacyBridgeChangeTimestamp;

    // ── Timelock: Ossification ────────────────────────────────────

    /// @notice Timestamp when ossification can be confirmed
    /// @dev L-01 audit fix: 48-hour propose/confirm pattern.
    ///      Zero means no pending ossification.
    uint256 public ossificationScheduledAt;

    // ── Timelock: Recipients (M-01 Round 6) ─────────────────────

    /// @notice Proposed staking pool address awaiting timelock
    /// @dev M-01 Round 6: replaces deprecated pendingStakingPool
    address public pendingNewStakingPool;

    /// @notice Proposed protocol treasury address awaiting timelock
    /// @dev M-01 Round 6: replaces deprecated pendingProtocolTreasury
    address public pendingNewProtocolTreasury;

    /// @notice Timestamp when proposed recipients can be applied
    /// @dev Zero means no pending change
    uint256 public recipientChangeTime;

    // ── Timelock: XOM Token (M-02 Round 6) ──────────────────────

    /// @notice Proposed XOM token address awaiting timelock
    /// @dev M-02 Round 6: prevents instant swap target manipulation
    address public pendingXomToken;

    /// @notice Timestamp when proposed XOM token can be applied
    /// @dev Zero means no pending change
    uint256 public xomTokenChangeTime;

    // ── Timelock: Bridge Mode (M-03 Round 6) ────────────────────

    /// @notice Token for pending bridge mode change
    /// @dev M-03 Round 6: prevents instant bridge mode manipulation
    address public pendingBridgeModeToken;

    /// @notice Proposed bridge mode awaiting timelock
    BridgeMode public pendingBridgeMode;

    /// @notice Timestamp when proposed bridge mode can be applied
    /// @dev Zero means no pending change
    uint256 public bridgeModeChangeTime;

    /// @notice Cumulative fees collected by this contract (in token wei)
    /// @dev AUDIT FIX (Round 6 FEE-AP-10): Cross-contract fee accounting.
    ///      Aggregates all fees across all tokens for a single total.
    uint256 public totalFeesCollected;

    /// @notice Storage gap for future upgrades
    /// @dev Budget: 15 original + 4 new + 3 deprecated + 8 M-01-03
    ///      + 1 totalFeesCollected = 31 slots used. Gap = 19.
    ///      Total = 50 (standard OZ budget).
    ///      Pioneer Phase: 3 recipient-timelock state variables
    ///      were deprecated (not removed) to preserve UUPS storage
    ///      layout compatibility. See __deprecated_* above.
    ///      M-01/M-02/M-03 Round 6: 8 new state variables added.
    ///      FEE-AP-10 Round 6: 1 new state variable added.
    ///      Reduce gap by N when adding N new state variables.
    uint256[19] private __gap;

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

    /// @notice Emitted when a new swap router is proposed
    /// @param router Proposed IFeeSwapRouter adapter address
    /// @param effectiveTimestamp When the change can be applied
    event SwapRouterProposed(
        address indexed router,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when the swap router is updated
    /// @param oldRouter Previous IFeeSwapRouter adapter address
    /// @param newRouter New IFeeSwapRouter adapter address
    event SwapRouterUpdated(
        address indexed oldRouter,
        address indexed newRouter
    );

    /// @notice Emitted when a new privacy bridge config is proposed
    /// @param bridge Proposed OmniPrivacyBridge address
    /// @param pxom Proposed PrivateOmniCoin address
    /// @param effectiveTimestamp When the change can be applied
    event PrivacyBridgeProposed(
        address indexed bridge,
        address indexed pxom,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when the privacy bridge config is updated
    /// @param oldBridge Previous OmniPrivacyBridge address
    /// @param newBridge New OmniPrivacyBridge address
    /// @param pxom New PrivateOmniCoin address
    event PrivacyBridgeUpdated(
        address indexed oldBridge,
        address indexed newBridge,
        address indexed pxom
    );

    /// @notice Emitted when the XOM token address is set
    /// @param xom New XOM token address
    event XOMTokenUpdated(address indexed xom);

    /// @notice Emitted when ossification is proposed
    /// @param effectiveTimestamp When ossification can be confirmed
    event OssificationProposed(uint256 indexed effectiveTimestamp);

    /// @notice Emitted when a recipient change is proposed (M-01 Round 6)
    /// @param stakingPool Proposed staking pool address
    /// @param protocolTreasury Proposed protocol treasury address
    /// @param effectiveTimestamp When the change can be applied
    event RecipientsProposed(
        address indexed stakingPool,
        address indexed protocolTreasury,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when a XOM token change is proposed (M-02 Round 6)
    /// @param xom Proposed XOM token address
    /// @param effectiveTimestamp When the change can be applied
    event XOMTokenProposed(
        address indexed xom,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when a bridge mode change is proposed (M-03 Round 6)
    /// @param token Token whose mode is being changed
    /// @param mode Proposed bridge mode
    /// @param effectiveTimestamp When the change can be applied
    event BridgeModeProposed(
        address indexed token,
        BridgeMode indexed mode,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when a pending claim is redirected by admin
    /// @param originalClaimant Address that originally held the claim
    /// @param newRecipient Address receiving the redirected claim
    /// @param token ERC20 token address
    /// @param amount Amount redirected
    event ClaimRedirected(
        address indexed originalClaimant,
        address indexed newRecipient,
        address indexed token,
        uint256 amount
    );

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

    /// @notice Thrown when a swap/conversion deadline has expired
    error DeadlineExpired();

    /// @notice Thrown when the timelock delay has not yet expired
    error TimelockNotExpired();

    /// @notice Thrown when no pending claim exists for redirect
    error NoPendingClaim();

    /// @notice Thrown when privacy bridge is not configured
    error PrivacyBridgeNotSet();

    /// @notice Thrown when sale amount is below minimum (M-04 Round 6)
    error SaleAmountTooSmall();

    // ════════════════════════════════════════════════════════════════════
    //                      CONSTRUCTOR & INITIALIZER
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Constructor that disables initializers for the
     *         implementation contract
     * @dev Sets the trusted forwarder address as an immutable
     *      (stored in bytecode, not proxy storage). Pass address(0)
     *      to disable meta-transaction support.
     * @param trustedForwarder_ Address of the OmniForwarder
     *        contract for gasless relay
     */
    /// @dev AUDIT ACCEPTED (Round 6): The trusted forwarder address is immutable by design.
    ///      ERC-2771 forwarder immutability is standard practice (OpenZeppelin default).
    ///      Changing the forwarder post-deployment would break all existing meta-transaction
    ///      infrastructure. If the forwarder is compromised, ossify() + governance pause
    ///      provides emergency protection. A new proxy can be deployed if needed.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address trustedForwarder_
    ) ERC2771ContextUpgradeable(trustedForwarder_) {
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
    ) external nonReentrant onlyRole(DEPOSITOR_ROLE) whenNotPaused {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        address caller = _msgSender();
        uint256 balBefore =
            IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(
            caller, address(this), amount
        );
        uint256 actualReceived =
            IERC20(token).balanceOf(address(this)) - balBefore;

        emit FeesDeposited(token, actualReceived, caller);
    }

    /**
     * @notice Notify the vault that fees arrived via direct transfer
     * @dev M-01 audit fix: RWAAMM sends fees via direct safeTransfer
     *      bypassing deposit(). This function emits FeesNotified so
     *      off-chain indexers can track all fee inflows. Restricted
     *      to DEPOSITOR_ROLE to prevent spoofed notifications from
     *      polluting the audit trail.
     * @param token ERC20 token address that was transferred
     * @param amount Amount that was transferred
     */
    function notifyDeposit(
        address token,
        uint256 amount
    ) external onlyRole(DEPOSITOR_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        emit FeesNotified(token, amount, _msgSender());
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
        // H-01 audit fix: subtract totalPendingClaims to avoid
        // double-counting claimable amounts as distributable.
        uint256 distributable = balance
            - pendingBridge[token]
            - totalPendingClaims[token];

        if (distributable == 0) revert NothingToDistribute();

        // L-03 audit fix: skip dust amounts that would break
        // the 70/20/10 split due to integer rounding.
        if (distributable < 10) return;

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
        // AUDIT FIX (Round 6 FEE-AP-10): Cross-contract fee accounting
        totalFeesCollected += distributable;

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
        address caller = _msgSender();
        uint256 amount = pendingClaims[caller][token];
        if (amount == 0) revert NothingToClaim();

        // C-01 audit fix: decrement global tracker before transfer
        pendingClaims[caller][token] = 0;
        totalPendingClaims[token] -= amount;

        IERC20(token).safeTransfer(caller, amount);

        emit PendingClaimWithdrawn(caller, token, amount);
    }

    // ════════════════════════════════════════════════════════════════════
    //                   MARKETPLACE FEE SETTLEMENT
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit and distribute a marketplace transaction fee
     * @dev Calculates the 1% marketplace fee split on-chain:
     *      - 0.50% transaction fee: 70% ODDAO, 20% staking pool,
     *        10% protocol treasury
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
     * @param referrer Referrer who referred the seller (zero if none)
     * @param referrerL2 Second-level referrer (zero if none)
     * @param listingNode Node where listing was created
     * @param sellingNode Node where buyer is shopping
     */
    function depositMarketplaceFee(
        address token,
        uint256 saleAmount,
        address referrer,
        address referrerL2,
        address listingNode,
        address sellingNode
    ) external nonReentrant onlyRole(DEPOSITOR_ROLE) whenNotPaused {
        if (token == address(0)) revert ZeroAddress();
        if (saleAmount == 0) revert ZeroAmount();
        // M-04 Round 6: Reject sub-dust sales that lose
        // precision in the 70/20/10 sub-splits
        if (saleAmount < MIN_SALE_AMOUNT) {
            revert SaleAmountTooSmall();
        }

        // Total fee = 1% of sale amount
        uint256 totalFee = saleAmount / 100;
        if (totalFee == 0) revert ZeroAmount();

        // H-01 audit fix: use _msgSender() for ERC-2771 meta-tx support
        address caller = _msgSender();

        // M-02 audit fix: balance-before/after for fee-on-transfer
        uint256 balBefore =
            IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(
            caller, address(this), totalFee
        );
        uint256 actualFee =
            IERC20(token).balanceOf(address(this)) - balBefore;

        // Use actualFee for all subsequent splits
        // Split 1: Transaction fee (0.50% = half of total fee)
        uint256 txFee = actualFee / 2;
        uint256 txOddao = (txFee * 7000) / 10000; // 70% ODDAO
        uint256 txStaking = (txFee * 2000) / 10000; // 20% staking
        uint256 txProtocol = txFee - txOddao - txStaking; // 10%

        pendingBridge[token] += txOddao;
        _safePushOrQuarantine(token, stakingPool, txStaking);
        _safePushOrQuarantine(
            token, protocolTreasury, txProtocol
        );

        // Split 2: Referral fee (0.25% = quarter of actual fee)
        uint256 refFee = actualFee / 4;
        uint256 refPrimary = (refFee * 7000) / 10000; // 70%
        uint256 refSecondary = (refFee * 2000) / 10000; // 20% L2
        uint256 refOddao = refFee - refPrimary - refSecondary;

        if (referrer != address(0)) {
            pendingClaims[referrer][token] += refPrimary;
            totalPendingClaims[token] += refPrimary;
        } else {
            pendingBridge[token] += refPrimary;
        }
        if (referrerL2 != address(0)) {
            pendingClaims[referrerL2][token] += refSecondary;
            totalPendingClaims[token] += refSecondary;
        } else {
            pendingBridge[token] += refSecondary;
        }
        pendingBridge[token] += refOddao;

        // Split 3: Listing fee (0.25% = remainder of actual fee)
        uint256 listFee = actualFee - txFee - refFee;
        uint256 listNode = (listFee * 7000) / 10000; // 70%
        uint256 sellNode = (listFee * 2000) / 10000; // 20%
        uint256 listOddao = listFee - listNode - sellNode; // 10%

        if (listingNode != address(0)) {
            pendingClaims[listingNode][token] += listNode;
            totalPendingClaims[token] += listNode;
        } else {
            pendingBridge[token] += listNode;
        }
        if (sellingNode != address(0)) {
            pendingClaims[sellingNode][token] += sellNode;
            totalPendingClaims[token] += sellNode;
        } else {
            pendingBridge[token] += sellNode;
        }
        pendingBridge[token] += listOddao;

        totalDistributed[token] += actualFee;
        // AUDIT FIX (Round 6 FEE-AP-10): Cross-contract fee accounting
        totalFeesCollected += actualFee;

        emit FeesDeposited(token, actualFee, caller);
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
    ) external nonReentrant onlyRole(BRIDGE_ROLE) whenNotPaused {
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
     * @notice Propose new staking pool and protocol treasury
     *         addresses with timelock (M-01 Round 6)
     * @dev Queues the change with a 48-hour timelock. Call
     *      `applyRecipients()` after the delay to apply.
     * @param _stakingPool Proposed StakingRewardPool address (20%)
     * @param _protocolTreasury Proposed protocol treasury address (10%)
     */
    function proposeRecipients(
        address _stakingPool,
        address _protocolTreasury
    ) external onlyRole(ADMIN_ROLE) {
        if (_stakingPool == address(0)) revert ZeroAddress();
        if (_protocolTreasury == address(0)) revert ZeroAddress();

        pendingNewStakingPool = _stakingPool;
        pendingNewProtocolTreasury = _protocolTreasury;
        // solhint-disable-next-line not-rely-on-time
        recipientChangeTime = block.timestamp + RECIPIENT_CHANGE_DELAY;

        emit RecipientsProposed(
            _stakingPool,
            _protocolTreasury,
            recipientChangeTime
        );
    }

    /**
     * @notice Apply pending recipient change after timelock
     *         (M-01 Round 6)
     * @dev Reverts if timelock has not elapsed or no pending
     *      change exists.
     */
    function applyRecipients()
        external
        onlyRole(ADMIN_ROLE)
    {
        if (pendingNewStakingPool == address(0)) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < recipientChangeTime) {
            revert TimelockNotExpired();
        }

        stakingPool = pendingNewStakingPool;
        protocolTreasury = pendingNewProtocolTreasury;
        delete pendingNewStakingPool;
        delete pendingNewProtocolTreasury;
        delete recipientChangeTime;

        emit RecipientsUpdated(stakingPool, protocolTreasury);
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
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // C-01 audit fix: include totalPendingClaims in committed
        // funds so admin cannot drain user-claimable balances.
        uint256 vaultBalance =
            IERC20(token).balanceOf(address(this));
        uint256 committed =
            pendingBridge[token] + totalPendingClaims[token];
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
     * @notice Propose permanent ossification of the contract
     * @dev L-01 audit fix: ossification now requires a 48-hour
     *      delay between proposal and confirmation to prevent
     *      accidental or malicious irreversible freezes.
     *      Only DEFAULT_ADMIN_ROLE can propose.
     */
    function proposeOssification()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // solhint-disable-next-line not-rely-on-time
        ossificationScheduledAt = block.timestamp + 48 hours;
        emit OssificationProposed(ossificationScheduledAt);
    }

    /**
     * @notice Confirm and execute permanent ossification
     * @dev Cannot be undone. The 48-hour timelock must have
     *      elapsed since proposeOssification() was called.
     *      Only DEFAULT_ADMIN_ROLE can confirm.
     */
    function confirmOssification()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (ossificationScheduledAt == 0) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < ossificationScheduledAt) {
            revert TimelockNotExpired();
        }

        _ossified = true;
        delete ossificationScheduledAt;
        emit ContractOssified(_msgSender());
    }

    // ── In-Kind / Swap-to-XOM Admin Configuration ────────────────

    /**
     * @notice Propose a bridge mode change for a specific token
     *         (M-03 Round 6)
     * @dev Queues the change with a 48-hour timelock. Call
     *      `applyTokenBridgeMode()` after the delay to apply.
     *      Prevents instant bridge mode manipulation.
     * @param token ERC20 token whose mode to change
     * @param mode Proposed bridge mode
     */
    function proposeTokenBridgeMode(
        address token,
        BridgeMode mode
    ) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();

        pendingBridgeModeToken = token;
        pendingBridgeMode = mode;
        // solhint-disable-next-line not-rely-on-time
        bridgeModeChangeTime = block.timestamp + RECIPIENT_CHANGE_DELAY;

        emit BridgeModeProposed(token, mode, bridgeModeChangeTime);
    }

    /**
     * @notice Apply pending bridge mode change after timelock
     *         (M-03 Round 6)
     * @dev Reverts if timelock has not elapsed or no pending
     *      change exists.
     */
    function applyTokenBridgeMode()
        external
        onlyRole(ADMIN_ROLE)
    {
        if (pendingBridgeModeToken == address(0)) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < bridgeModeChangeTime) {
            revert TimelockNotExpired();
        }

        tokenBridgeMode[pendingBridgeModeToken] = pendingBridgeMode;

        emit TokenBridgeModeSet(
            pendingBridgeModeToken, pendingBridgeMode
        );

        delete pendingBridgeModeToken;
        delete pendingBridgeMode;
        delete bridgeModeChangeTime;
    }

    /**
     * @notice Propose a new IFeeSwapRouter adapter address
     * @dev H-03 audit fix: swap router changes are timelocked to
     *      prevent instant diversion of swap proceeds from a
     *      compromised ADMIN_ROLE key. After RECIPIENT_CHANGE_DELAY
     *      (48h), call applySwapRouter() to finalize.
     * @param _router Proposed FeeSwapAdapter contract address
     */
    function proposeSwapRouter(
        address _router
    ) external onlyRole(ADMIN_ROLE) {
        if (_router == address(0)) revert ZeroAddress();

        pendingSwapRouter = _router;
        /* solhint-disable not-rely-on-time */
        swapRouterChangeTimestamp =
            block.timestamp + RECIPIENT_CHANGE_DELAY;
        /* solhint-enable not-rely-on-time */
        emit SwapRouterProposed(
            _router, swapRouterChangeTimestamp
        );
    }

    /**
     * @notice Apply the pending swap router change after timelock
     * @dev Reverts if timelock has not elapsed or no pending change
     *      exists. Only ADMIN_ROLE can execute.
     */
    function applySwapRouter()
        external
        onlyRole(ADMIN_ROLE)
    {
        if (pendingSwapRouter == address(0)) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < swapRouterChangeTimestamp) {
            revert TimelockNotExpired();
        }

        address old = swapRouter;
        swapRouter = pendingSwapRouter;
        delete pendingSwapRouter;
        delete swapRouterChangeTimestamp;
        emit SwapRouterUpdated(old, swapRouter);
    }

    /**
     * @notice Propose a new XOM token address with timelock
     *         (M-02 Round 6)
     * @dev Queues the change with a 48-hour timelock. Call
     *      `applyXomToken()` after the delay to apply.
     *      Prevents instant swap target manipulation by a
     *      compromised admin key.
     * @param _xomToken Proposed OmniCoin ERC20 address
     */
    function proposeXomToken(
        address _xomToken
    ) external onlyRole(ADMIN_ROLE) {
        if (_xomToken == address(0)) revert ZeroAddress();

        pendingXomToken = _xomToken;
        // solhint-disable-next-line not-rely-on-time
        xomTokenChangeTime = block.timestamp + RECIPIENT_CHANGE_DELAY;

        emit XOMTokenProposed(_xomToken, xomTokenChangeTime);
    }

    /**
     * @notice Apply pending XOM token change after timelock
     *         (M-02 Round 6)
     * @dev Reverts if timelock has not elapsed or no pending
     *      change exists.
     */
    function applyXomToken()
        external
        onlyRole(ADMIN_ROLE)
    {
        if (pendingXomToken == address(0)) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < xomTokenChangeTime) {
            revert TimelockNotExpired();
        }

        xomToken = pendingXomToken;
        delete pendingXomToken;
        delete xomTokenChangeTime;

        emit XOMTokenUpdated(xomToken);
    }

    /**
     * @notice Propose new OmniPrivacyBridge and pXOM addresses
     * @dev H-03 audit fix: privacy bridge changes are timelocked
     *      to prevent instant diversion of pXOM conversion flow.
     *      After RECIPIENT_CHANGE_DELAY (48h), call
     *      applyPrivacyBridge() to finalize.
     * @param _bridge Proposed OmniPrivacyBridge contract address
     * @param _pxom Proposed PrivateOmniCoin (pXOM) ERC20 address
     */
    function proposePrivacyBridge(
        address _bridge,
        address _pxom
    ) external onlyRole(ADMIN_ROLE) {
        if (_bridge == address(0)) revert ZeroAddress();
        if (_pxom == address(0)) revert ZeroAddress();

        pendingPrivacyBridgeAddr = _bridge;
        pendingPXOMToken = _pxom;
        /* solhint-disable not-rely-on-time */
        privacyBridgeChangeTimestamp =
            block.timestamp + RECIPIENT_CHANGE_DELAY;
        /* solhint-enable not-rely-on-time */
        emit PrivacyBridgeProposed(
            _bridge, _pxom, privacyBridgeChangeTimestamp
        );
    }

    /**
     * @notice Apply the pending privacy bridge change after timelock
     * @dev Reverts if timelock has not elapsed or no pending change
     *      exists. Only ADMIN_ROLE can execute.
     */
    function applyPrivacyBridge()
        external
        onlyRole(ADMIN_ROLE)
    {
        if (pendingPrivacyBridgeAddr == address(0)) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < privacyBridgeChangeTimestamp) {
            revert TimelockNotExpired();
        }

        address oldBridge = privacyBridge;
        privacyBridge = pendingPrivacyBridgeAddr;
        pxomToken = pendingPXOMToken;
        delete pendingPrivacyBridgeAddr;
        delete pendingPXOMToken;
        delete privacyBridgeChangeTimestamp;
        emit PrivacyBridgeUpdated(
            oldBridge, privacyBridge, pxomToken
        );
    }

    // ── Swap-and-Bridge Functions ────────────────────────────────

    /**
     * @notice Swap a fee token to XOM and bridge to ODDAO treasury
     * @dev Deducts from pendingBridge[token], swaps via the
     *      IFeeSwapRouter adapter, and transfers XOM to receiver.
     *      Uses balance-before/after to verify received amount.
     *      M-03 audit fix: deadline parameter prevents stale
     *      transactions from executing at unfavorable prices.
     * @param token ERC20 fee token to swap
     * @param amount Amount of token to swap (must be <= pending)
     * @param minXOMOut Minimum XOM output (slippage protection)
     * @param bridgeReceiver Address to receive the XOM
     * @param deadline Timestamp by which the swap must execute
     */
    function swapAndBridge(
        address token,
        uint256 amount,
        uint256 minXOMOut,
        address bridgeReceiver,
        uint256 deadline
    )
        external
        nonReentrant
        onlyRole(BRIDGE_ROLE)
        whenNotPaused
    {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert DeadlineExpired();
        _validateSwapBridge(token, bridgeReceiver, amount);

        // Effects (CEI)
        pendingBridge[token] -= amount;
        totalBridged[token] += amount;

        // Interactions: approve adapter, execute swap
        IERC20(token).forceApprove(swapRouter, amount);

        uint256 xomBefore =
            IERC20(xomToken).balanceOf(address(this));

        IFeeSwapRouter(swapRouter).swapExactInput(
            token, xomToken, amount, minXOMOut,
            address(this), deadline
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
     *      M-04 audit fix: minXOMOut parameter provides slippage
     *      protection against unfavorable pXOM→XOM conversion.
     * @param amount Amount of pXOM to convert (must be <= pending)
     * @param bridgeReceiver Address to receive the XOM
     * @param minXOMOut Minimum XOM output (slippage protection)
     */
    function convertPXOMAndBridge(
        uint256 amount,
        address bridgeReceiver,
        uint256 minXOMOut
    )
        external
        nonReentrant
        onlyRole(BRIDGE_ROLE)
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
        // M-04 audit fix: enforce minimum output
        if (xomReceived < minXOMOut) {
            revert InsufficientSwapOutput(xomReceived, minXOMOut);
        }

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
     * @dev This is the amount available for the next distribute()
     *      call. Equals the vault's token balance minus the ODDAO
     *      share (pendingBridge) and user-claimable amounts
     *      (totalPendingClaims) that are already committed.
     * @param token ERC20 token address to query
     * @return Undistributed token balance
     */
    function undistributed(
        address token
    ) external view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 committed =
            pendingBridge[token] + totalPendingClaims[token];
        if (balance < committed) return 0;
        return balance - committed;
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

    /**
     * @notice Redirect a stuck pending claim to a new recipient
     * @dev L-04 audit fix: if a claimant is blacklisted by a token
     *      (e.g., USDC) and cannot receive transfers, an admin can
     *      redirect the claim to a new address so the funds are not
     *      permanently stuck.
     *      Only DEFAULT_ADMIN_ROLE can call.
     * @param originalClaimant Address that currently holds the claim
     * @param newRecipient Address to receive the redirected claim
     * @param token ERC20 token address of the claim
     */
    function redirectStuckClaim(
        address originalClaimant,
        address newRecipient,
        address token
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRecipient == address(0)) revert ZeroAddress();

        uint256 amount =
            pendingClaims[originalClaimant][token];
        if (amount == 0) revert NoPendingClaim();

        pendingClaims[originalClaimant][token] = 0;
        pendingClaims[newRecipient][token] += amount;

        emit ClaimRedirected(
            originalClaimant, newRecipient, token, amount
        );
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
        // H-02 audit fix: decode return data and check boolean.
        // Some ERC20 tokens return false instead of reverting.
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = address(token)
            .call(
                abi.encodeWithSelector(
                    IERC20.transfer.selector,
                    recipient,
                    amount
                )
            );

        bool transferred = success
            && (returndata.length == 0
                || abi.decode(returndata, (bool)));

        if (!transferred) {
            // C-01 audit fix: track global pending claims total
            /* solhint-disable reentrancy */
            pendingClaims[recipient][token] += amount;
            totalPendingClaims[token] += amount;
            /* solhint-enable reentrancy */
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

    // ════════════════════════════════════════════════════════════════════
    //           ERC2771Context Overrides (resolve diamond)
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Resolve _msgSender between ContextUpgradeable and
     *         ERC2771ContextUpgradeable
     * @dev Returns the original user address when called through
     *      the trusted forwarder. Used by claimPending() to
     *      identify the actual claimant.
     * @return The original transaction signer when relayed, or
     *         msg.sender when direct
     */
    function _msgSender()
        internal
        view
        override(
            ContextUpgradeable,
            ERC2771ContextUpgradeable
        )
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    /**
     * @notice Resolve _msgData between ContextUpgradeable and
     *         ERC2771ContextUpgradeable
     * @dev Strips the appended sender address from calldata
     *      when relayed
     * @return The original calldata without the ERC2771 suffix
     */
    function _msgData()
        internal
        view
        override(
            ContextUpgradeable,
            ERC2771ContextUpgradeable
        )
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    /**
     * @notice Resolve _contextSuffixLength between
     *         ContextUpgradeable and ERC2771ContextUpgradeable
     * @dev Returns 20 (address length) for ERC2771 context
     *      suffix stripping
     * @return The number of bytes appended to calldata by the
     *         forwarder (20)
     */
    function _contextSuffixLength()
        internal
        view
        override(
            ContextUpgradeable,
            ERC2771ContextUpgradeable
        )
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }
}
