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
import {ERC2771ContextUpgradeable} from
    "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {ContextUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {IActivityLedger} from "./interfaces/IActivityLedger.sol";

// ══════════════════════════════════════════════════════════════════════
//                              INTERFACES
// ══════════════════════════════════════════════════════════════════════

/**
 * @title IBootstrapRewards
 * @author OmniBazaar Team
 * @notice Minimal interface for Bootstrap.sol node registry
 * @dev Used by OmniValidatorRewards V2 to auto-derive role multipliers.
 *      Bootstrap.sol maintains node types: 0=gateway, 1=computation, 2=listing.
 */
interface IBootstrapRewards {
    /// @notice Check if a node is active and get its type
    /// @param nodeAddress Address of the node to check
    /// @return isActive Whether the node is currently active
    /// @return nodeType Node type (0=gateway, 1=computation, 2=listing)
    function isNodeActive(
        address nodeAddress
    ) external view returns (bool isActive, uint8 nodeType);
}

/**
 * @title IOmniParticipation
 * @author OmniBazaar Team
 * @notice Interface for OmniParticipation contract
 * @dev Queries participation scores for reward weighting
 */
interface IOmniParticipation {
    /// @notice Get user's total participation score
    /// @param user Address to check
    /// @return Total score (0-100)
    function getTotalScore(
        address user
    ) external view returns (uint256);

    /// @notice Check if user can be a validator
    /// @param user Address to check
    /// @return True if qualified
    function canBeValidator(
        address user
    ) external view returns (bool);
}

/**
 * @title IOmniCore
 * @author OmniBazaar Team
 * @notice Interface for OmniCore contract
 * @dev Queries staking and validator status
 */
interface IOmniCore {
    /// @notice Stake information structure
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 duration;
        uint256 lockTime;
        bool active;
    }

    /// @notice Get user's stake information
    /// @param user Address to check
    /// @return Stake struct with staking details
    function getStake(
        address user
    ) external view returns (Stake memory);

    /// @notice Check if address is a validator
    /// @param validator Address to check
    /// @return True if validator
    function isValidator(
        address validator
    ) external view returns (bool);

    /// @notice Get all active nodes
    /// @return Array of active node addresses
    function getActiveNodes()
        external
        view
        returns (address[] memory);
}

/**
 * @title ILiquidityOverflowPool
 * @author OmniBazaar Team
 * @notice Minimal interface for LiquidityOverflowPool overflow distribution
 * @dev V3: ValidatorRewards pushes excess rewards to this pool each epoch
 */
interface ILiquidityOverflowPool {
    /// @notice Receive and distribute overflow rewards
    /// @param amount XOM overflow amount to distribute
    function distributeOverflow(uint256 amount) external;
}

// Grouping the ICTT (Avalanche Inter-Chain Token Transfer) type
// mirrors with the other interfaces above keeps the V4 cross-chain
// types together for readability. Solhint's "structs before
// interfaces" rule does not fit this layout, so it is disabled for
// the type-mirror block.
// solhint-disable ordering

/**
 * @title SendTokensInput
 * @author OmniBazaar Team
 * @notice ICTT (Avalanche Inter-Chain Token Transfer) send-tokens
 *         input. Mirrors the canonical struct from
 *         `bridge/ictt/interfaces/ITokenTransferrer.sol`.
 * @dev Declared locally so this rewards contract does not pull the
 *      full ICTT inheritance / build surface. Field semantics match
 *      the canonical struct verbatim.
 * @param destinationBlockchainID Avalanche blockchain ID of the
 *        destination chain.
 * @param destinationTokenTransferrerAddress Address of the
 *        `ERC20TokenRemote` (or equivalent) on the destination chain
 *        that will mint the bridged token.
 * @param recipient Address on the destination chain that receives
 *        the bridged token (typically a contract — for LP-5, the
 *        `OverflowOFTSender` on Avalanche C-Chain).
 * @param primaryFeeTokenAddress ERC-20 token for the Teleporter
 *        primary fee. Set to `address(0)` and `primaryFee = 0` when
 *        an OmniBazaar validator self-relays (no fee).
 * @param primaryFee Amount of `primaryFeeTokenAddress` to pay the
 *        Teleporter relayer on the source chain.
 * @param secondaryFee Amount for multi-hop relay. Always 0 here
 *        (single hop L1 → C-Chain).
 * @param requiredGasLimit Gas budget for the destination's Teleporter
 *        `receive` callback (ERC-20 mint + transfer). 250_000 default.
 * @param multiHopFallback Unused for single-hop; pass `address(0)`.
 */
struct SendTokensInput {
    bytes32 destinationBlockchainID;
    address destinationTokenTransferrerAddress;
    address recipient;
    address primaryFeeTokenAddress;
    uint256 primaryFee;
    uint256 secondaryFee;
    uint256 requiredGasLimit;
    address multiHopFallback;
}

/**
 * @title IICTTSender
 * @author OmniBazaar Team
 * @notice Minimal subset of `IERC20TokenTransferrer` used by
 *         `OmniValidatorRewards._routeOverflow` to bridge overflow
 *         XOM from L1 to a single C-Chain recipient (the
 *         `OverflowOFTSender`).
 * @dev We declare only `send`. The full interface lives at
 *      `bridge/ictt/interfaces/IERC20TokenTransferrer.sol`. ICTT
 *      `send` is NOT payable — fees are paid in `primaryFeeTokenAddress`
 *      ERC-20 declared inside `SendTokensInput`. Setting
 *      `primaryFee = 0` lets any validator (which already run
 *      Teleporter relayers) carry the message at no cost.
 */
interface IICTTSender {
    /// @notice Send `amount` of the underlying ERC-20 to a single
    ///         destination on another Avalanche blockchain.
    /// @dev The caller MUST hold + approve the underlying ERC-20 to
    ///      this contract for `amount` (lock/release pattern on home).
    /// @param input Destination + fee + gas configuration.
    /// @param amount Amount of underlying ERC-20 to bridge.
    function send(
        SendTokensInput calldata input,
        uint256 amount
    ) external;
}
// solhint-enable ordering

/**
 * @title OmniValidatorRewards
 * @author OmniBazaar Team
 * @notice Trustless validator reward distribution for OmniBazaar
 * @dev Time-based epoch distribution with participation weighting.
 *
 * Weight Calculation:
 * - 40% participation score (from OmniParticipation)
 * - 30% staking amount (from OmniCore)
 * - 30% activity (heartbeat + transaction processing)
 *
 * Relationship Between Block Rewards and Validator Rewards:
 *   Block rewards are the primary funding source for this contract.
 *   The Validator Rewards pool is pre-funded at genesis with 6.089B XOM
 *   (via OmniRewardManager). Rewards are distributed via transfer at the
 *   emission schedule rate. Validators earn rewards proportional to
 *   their weighted participation score.
 *   The per-epoch reward is calculated using the same emission
 *   schedule as block rewards (15.602 XOM initial, 1% reduction
 *   per 6,311,520 epochs).
 *
 * Reward Distribution:
 * - Epoch every 2 seconds (tied to block time)
 * - Rewards accumulate in contract
 * - Validators claim via claimRewards()
 *
 * Block Reward Schedule:
 * - Initial: 15.602 XOM per block
 * - Reduction: 1% every 6,311,520 blocks
 * - Target: 6.089 billion XOM over 40 years
 *
 * Security:
 * - Pausable by admin for emergency scenarios
 * - Sequential epoch enforcement prevents reward destruction
 * - Retired validators can still claim earned rewards
 * - 48h timelock on contract reference updates
 * - 48h timelock on UUPS upgrades (H-01 audit fix Round 3)
 * - Flash-stake protection via lock expiry check
 * - Validator iteration capped at 200 per epoch
 * - Transaction recording capped at 1000 per call
 * - Epoch processing restricted to BLOCKCHAIN_ROLE (M-07)
 * - Batch processing capped at 50 epochs (M-03)
 * - External calls wrapped in try/catch (M-01 Round 3)
 * - Total outstanding rewards tracked for solvency (M-02 R3)
 * - Ossification mechanism for permanent upgrade lockdown
 *
 * Planned Ossification Timeline (M-04 audit recommendation):
 *   After initial deployment and a minimum 6-month tuning period
 *   on mainnet, the admin (via governance vote) should call
 *   ossify() to permanently freeze the contract. Once ossified:
 *   - No further UUPS upgrades are possible
 *   - Reward parameters become immutable
 *   - Only epoch processing, heartbeats, and claims continue
 *   - Admin retains pause/unpause and contract reference updates
 *   Post-ossification risk rating drops from 7/10 to 3/10.
 *
 * Audit Fixes (2026-02-22):
 * - M-02: Reward reduction based on epoch number (time-based)
 * - M-03: Batch processing capped at MAX_BATCH_EPOCHS (50)
 * - M-04: Staking score uses linear interpolation
 * - M-05: Graduated heartbeat scoring (not binary)
 * - M-07: processEpoch restricted to BLOCKCHAIN_ROLE
 *
 * Audit Fixes (2026-02-26 Round 3):
 * - H-01: Upgrade timelock (propose/apply with 48h delay)
 * - M-01: External calls wrapped in try/catch
 * - M-02: totalOutstandingRewards accumulator for solvency
 * - M-03: MAX_BATCH_EPOCHS documented (50 = 100s catch-up)
 * - M-04: Ossification timeline documented
 *
 * Gateway Role Bonus (2026-02-27):
 * - roleMultiplier mapping: basis-point multiplier per validator
 *   (10000 = 1.0x, 15000 = 1.5x). Separate from penalty
 *   rewardMultiplier (0-100 scale) which cannot represent >1.0x.
 * - Gateway validators earn 1.5x to offset AVAX staking costs
 *   and avalanchego infrastructure overhead.
 * - Anti-gaming: bonus only applied when _heartbeatScore > 0
 *   (active heartbeat within 20s). Offline = no bonus.
 * - Max cap: 20000 bps (2.0x) to prevent abuse.
 * - Access: ROLE_MANAGER_ROLE (granted to deployer + validators).
 *
 * Audit Fixes (2026-02-28 Round 4):
 * - H-01: emergencyWithdraw checks both current and original XOM
 * - M-01: roleMultiplier capped at MAX_ROLE_MULTIPLIER (15000)
 * - M-02: Penalty decay with MAX_PENALTY_DURATION (30 days)
 * - M-03: Stale validator state documented as accepted behavior
 * - M-04: Per-epoch per-validator transaction count cap (1000)
 * - M-05: claimRewards() available during pause (withdrawal)
 * - L-01: Rounding dust documented as acceptable
 * - L-02: Sub-base roleMultiplier values rejected
 * - L-03: getActiveNodes memory allocation documented
 * - I-01: nonReentrant modifier placed first
 * - I-03: Activity component uses single division for precision
 *
 * V2 Upgrade (2026-03):
 * - Permissionless epoch processing: removed BLOCKCHAIN_ROLE from
 *   processEpoch() and processMultipleEpochs(). All nodes race to
 *   call; sequential epoch check prevents double-processing.
 * - Auto role multiplier: reads nodeType from Bootstrap.sol instead
 *   of requiring manual setRoleMultiplier() calls. Gateways (type 0)
 *   automatically get 1.5x when heartbeat is active. Manual override
 *   via setRoleMultiplier() still takes precedence if non-zero.
 * - Bootstrap.sol reference: added bootstrapContract state variable
 *   set via reinitializeV2().
 *
 * Audit Fixes (2026-03-13 Round 7):
 * - H-01: _bootstrapRoleMultiplier cross-checks OmniCore stake
 *   before granting 1.5x gateway bonus; minStakeForRewards
 *   defaults to 1M XOM (not 0) for Sybil protection from deploy.
 * - M-01: Removed redundant _epochTxnCount mapping (renamed to
 *   __removed_epochTxnCount for storage layout preservation).
 *   Cap checks now use transactionsProcessed directly.
 *
 * V3 Upgrade (2026-03 — Adaptive Validator Cap):
 * - Per-node-type reward caps: gateway (0.3 XOM/epoch) and service
 *   node (0.2 XOM/epoch) caps applied in _distributeRewards.
 * - Overflow routing: excess rewards beyond caps are automatically
 *   pushed to LiquidityOverflowPool for LP incentives.
 * - No admin rate-setting ever needed — overflow IS the LP reward.
 * - Circuit breaker: overflowEnabled flag to disable routing.
 * - Dust threshold: minOverflowTransfer prevents tiny transfers.
 * - New storage: gatewayRewardCap, serviceNodeRewardCap,
 *   overflowPool, overflowEnabled, totalOverflowTransferred,
 *   minOverflowTransfer (6 slots from __gap: 50→44).
 *
 * V6 Upgrade (2026-09 — LP-5 hop-1 flood fix, Option C):
 * - The cross-chain (ICTT) overflow bucket is now BATCHED: it
 *   accumulates in `pendingCrossChainOverflow` (1 slot from __gap:
 *   39→38) and is sent as ONE ICTT message when the accumulator
 *   reaches `minOverflowTransfer` (re-purposed as the batch trigger).
 *   The per-epoch message flood on the shared L1↔CChain user-bridge
 *   lane (~35K msgs/day) drops to the batch cadence (~1/day at the
 *   calibrated threshold). The L1 `LiquidityOverflowPool` leg stays
 *   per-epoch, unchanged.
 * - Node-type caps restored: `reinitializeV5` re-points
 *   `bootstrapContract` at the live Bootstrap registry so active
 *   gateways (nodeType 0) resolve to `gatewayRewardCap` instead of
 *   every validator falling back to the 1-wei service cap.
 * - Solvency: the pending bucket is excluded from `availableForRewards`
 *   and `totalDistributed` bumps at commit (local leg on push,
 *   cross-chain leg on ICTT send).
 */
// solhint-disable max-states-count
contract OmniValidatorRewards is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ERC2771ContextUpgradeable
{
// solhint-enable max-states-count
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════════
    //                          TYPE DECLARATIONS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Pending contract references awaiting timelock
    /// @dev Set via proposeContracts(), applied via applyContracts()
    struct PendingContractsUpdate {
        address xomToken;
        address participation;
        address omniCore;
        uint256 effectiveTimestamp;
    }

    /// @notice Pending upgrade awaiting timelock
    /// @dev Set via proposeUpgrade(), checked in _authorizeUpgrade()
    struct PendingUpgrade {
        address newImplementation;
        uint256 effectiveTimestamp;
    }

    // ══════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Role for recording transaction processing
    bytes32 public constant BLOCKCHAIN_ROLE =
        keccak256("BLOCKCHAIN_ROLE");

    /// @notice Role for applying reward penalties
    bytes32 public constant PENALTY_ROLE =
        keccak256("PENALTY_ROLE");

    /// @notice Role for managing gateway/service-node role multipliers
    bytes32 public constant ROLE_MANAGER_ROLE =
        keccak256("ROLE_MANAGER_ROLE");

    /// @notice Maximum role multiplier in basis points (1.5x cap)
    /// @dev Audit H-01 Round 4: Prevents ROLE_MANAGER from
    ///      concentrating rewards via unbounded multipliers.
    ///      Reduced from 20000 (2.0x) to 15000 (1.5x).
    uint256 public constant MAX_ROLE_MULTIPLIER = 15000;

    /// @notice Maximum penalty duration before auto-reset
    /// @dev Audit M-02 Round 4: Prevents indefinite reward
    ///      suppression by PENALTY_ROLE. After 30 days the
    ///      penalty automatically expires and multiplier
    ///      resets to default (100%).
    uint256 public constant MAX_PENALTY_DURATION = 30 days;

    /// @notice Maximum transactions per epoch per validator
    /// @dev Audit M-04 Round 4: Prevents BLOCKCHAIN_ROLE from
    ///      inflating a single validator's transaction count
    ///      within one epoch. 1000 txns at 2s epochs is generous.
    uint256 public constant MAX_TXN_PER_EPOCH_PER_VALIDATOR =
        1000;

    /// @notice Epoch duration in seconds (2 second blocks)
    uint256 public constant EPOCH_DURATION = 2;

    /// @notice V5: Largest un-skipped backlog {unpause} will resume into
    ///         without {skipToEpoch} having been called first
    /// @dev 43,200 epochs = 24h of backlog at `EPOCH_DURATION`. An
    ///      ordinary short operational pause resumes fine under this
    ///      bound; a pause left long enough to build a real backlog
    ///      forces the admin to make an explicit choice — call
    ///      {skipToEpoch} to forgive it, or process it for real — rather
    ///      than having a forgotten backlog become permissionlessly
    ///      payable the instant `unpause()` lands. Not a time delay
    ///      (no `block.timestamp` involved): the check is against the
    ///      epoch *count* still pending at the moment `unpause()` is
    ///      called, evaluated once, synchronously, in that same call.
    uint256 public constant MAX_UNSKIPPED_PENDING_EPOCHS = 43_200;

    /// @notice Heartbeat/attestation timeout for active status (90s = 45 epochs)
    /// @dev V5: widened from 20s — the 20s window predates the VT-18
    ///      committee-attestation activity model and is shorter than the
    ///      activity tally's own 60s sweep floor, capping honest validators
    ///      at ~33% duty cycle. 90s keeps "rapid" ejection of missing
    ///      validators (~90s) while allowing continuous activity from the
    ///      always-on committee attestation stream (marketplace anchor).
    uint256 public constant HEARTBEAT_TIMEOUT = 90;

    /// @notice Initial block reward (15.602 XOM with 18 decimals)
    uint256 public constant INITIAL_BLOCK_REWARD =
        15_602_000_000_000_000_000;

    /// @notice Blocks per reduction period (6,311,520 blocks)
    uint256 public constant BLOCKS_PER_REDUCTION = 6_311_520;

    /// @notice Reward reduction factor (99% = keep 99%, reduce 1%)
    uint256 public constant REDUCTION_FACTOR = 99;

    /// @notice Reduction factor denominator
    uint256 public constant REDUCTION_DENOMINATOR = 100;

    /// @notice Maximum reductions before zero reward (~40 years)
    uint256 public constant MAX_REDUCTIONS = 100;

    /// @notice Weight for participation score (40%)
    uint256 public constant PARTICIPATION_WEIGHT = 40;

    /// @notice Weight for staking amount (30%)
    uint256 public constant STAKING_WEIGHT = 30;

    /// @notice Weight for activity (30%)
    uint256 public constant ACTIVITY_WEIGHT = 30;

    /// @notice Activity sub-weight for heartbeat (60%)
    uint256 public constant HEARTBEAT_SUBWEIGHT = 60;

    /// @notice Activity sub-weight for transaction processing (40%)
    uint256 public constant TX_PROCESSING_SUBWEIGHT = 40;

    /// @notice Maximum transactions recordable in a single call
    uint256 public constant MAX_TX_BATCH = 1000;

    /// @notice Maximum validators processed per epoch
    /// @dev Prevents gas DoS when validator set grows large
    uint256 public constant MAX_VALIDATORS_PER_EPOCH = 200;

    /// @notice Maximum epochs processable in a single batch
    /// @dev Limits state drift when processing historical epochs
    ///      with current validator/heartbeat state (M-03 fix).
    ///      50 epochs = 100 seconds of catch-up per batch.
    ///      At 200 validators max per epoch, worst-case gas is
    ///      50 * 200 = 10,000 weight calculations per batch,
    ///      well within Avalanche block gas limits.
    uint256 public constant MAX_BATCH_EPOCHS = 50;

    /// @notice Timelock delay for contract reference updates
    /// @dev 48 hours in seconds
    uint256 public constant CONTRACT_UPDATE_DELAY = 48 hours;

    /// @notice Timelock delay for UUPS upgrades
    /// @dev H-01 Round 3 audit fix: 48 hours to allow monitoring
    ///      and intervention before an upgrade takes effect.
    ///      MUST be used with a multisig wallet for production.
    uint256 public constant UPGRADE_DELAY = 48 hours;

    /// @notice Timelock delay for admin role transfer
    /// @dev V2: Two-step admin transfer requires 48h wait to prevent
    ///      accidental lockout and allow monitoring.
    uint256 public constant ADMIN_TRANSFER_DELAY = 48 hours;

    /// @notice Total validator reward pool (6.089 billion XOM)
    /// @dev H-01 Round 6: Hard cap on total distributable rewards.
    ///      OmniRewardManager pre-funds this contract with exactly
    ///      this amount. Distribution MUST NOT exceed this total.
    uint256 public constant TOTAL_VALIDATOR_POOL =
        6_089_000_000 ether;

    /// @notice Threshold in basis points for low-pool warnings
    /// @dev H-01 Round 6: Emits PoolRunningLow when remaining
    ///      pool drops below 10% (1000 bps) of TOTAL_VALIDATOR_POOL.
    uint256 public constant POOL_LOW_THRESHOLD_BPS = 1000;

    /// @notice Basis-points denominator for overflow share splits.
    /// @dev V4: The cross-chain bucket is `overflow * remoteShareBps
    ///      / BPS_DENOMINATOR`; the local L1 share is the complement.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Default ICTT `requiredGasLimit` for the C-Chain
    ///         Teleporter receive callback (single-hop ERC-20 mint
    ///         + transfer).
    /// @dev V4: 250,000 gas is generous for the mint + ERC-20
    ///      transfer-to-recipient that ICTT performs on delivery.
    ///      Cap is consumed by the C-Chain Teleporter messenger, not
    ///      paid for by this contract.
    uint256 public constant ICTT_DEFAULT_GAS_LIMIT = 250_000;

    // ══════════════════════════════════════════════════════════════════
    //                              STORAGE
    // ══════════════════════════════════════════════════════════════════

    /// @notice XOM token contract
    IERC20 public xomToken;

    /// @notice OmniParticipation contract reference
    IOmniParticipation public participation;

    /// @notice OmniCore contract reference
    IOmniCore public omniCore;

    /// @notice Genesis block timestamp
    uint256 public genesisTimestamp;

    /// @notice Last processed epoch
    uint256 public lastProcessedEpoch;

    /// @notice Total blocks produced (for monitoring only)
    /// @dev Not used in reward calculation (epoch-based instead).
    ///      Kept for off-chain monitoring and transparency.
    uint256 public totalBlocksProduced;

    /// @notice Accumulated rewards per validator
    mapping(address => uint256) public accumulatedRewards;

    /// @notice Total rewards claimed per validator
    mapping(address => uint256) public totalClaimed;

    /// @notice Last heartbeat timestamp per validator
    mapping(address => uint256) public lastHeartbeat;

    /// @notice Transactions processed per validator per epoch
    mapping(address => mapping(uint256 => uint256))
        public transactionsProcessed;

    /// @notice Total transactions in an epoch
    mapping(uint256 => uint256) public epochTotalTransactions;

    /// @notice Active validators count at epoch end
    mapping(uint256 => uint256) public epochActiveValidators;

    /// @notice Pending contract reference update with timelock
    PendingContractsUpdate public pendingContracts;

    /// @notice Whether contract is ossified (permanently non-upgradeable)
    bool private _ossified;

    /// @notice Total outstanding (unclaimed) rewards across all validators
    /// @dev M-02 Round 3 audit fix: tracks total allocated but unclaimed
    ///      rewards. Enables solvency check: balance >= totalOutstanding.
    uint256 public totalOutstandingRewards;

    /// @notice Pending upgrade awaiting timelock
    /// @dev H-01 Round 3 audit fix: UUPS upgrades require proposal +
    ///      48h delay before execution
    PendingUpgrade public pendingUpgrade;

    /// @notice Reward multiplier per validator (0-100 percentage)
    /// @dev Defaults to 0 which is treated as 100% (full rewards).
    ///      Set via setRewardMultiplier() by PENALTY_ROLE.
    ///      0 = default (100%), 1-100 = explicit multiplier.
    mapping(address => uint256) public rewardMultiplier;

    /// @notice Role-based reward multiplier in basis points
    /// @dev Gateway validators earn 1.5x (15000 bps) vs service
    ///      nodes at 1.0x (10000 bps). Set via setRoleMultiplier()
    ///      by ROLE_MANAGER_ROLE. Unset (0) defaults to 10000 (1.0x).
    ///      Only applied when validator has an active heartbeat,
    ///      preventing offline nodes from claiming the bonus.
    mapping(address => uint256) public roleMultiplier;

    /// @notice Original XOM token address set at initialization
    /// @dev Audit H-01 Round 4: Prevents emergencyWithdraw bypass
    ///      via proposeContracts/applyContracts swapping xomToken.
    ///      Set once in initialize(), never changed thereafter.
    address private _originalXomToken;

    /// @notice Penalty expiration timestamp per validator
    /// @dev Audit M-02 Round 4: Penalties auto-expire after
    ///      MAX_PENALTY_DURATION (30 days). After expiry, the
    ///      rewardMultiplier resets to 0 (default = 100%).
    mapping(address => uint256) public penaltyExpiresAt;

    /// @notice REMOVED — was per-epoch per-validator txn count
    /// @dev M-01 Round 7 fix: Renamed to preserve storage layout
    ///      (UUPS upgradeable). Replaced by transactionsProcessed
    ///      which already tracks the same data. DO NOT write to.
    ///      Underscore prefix is intentional and locked — renaming
    ///      would shift every subsequent storage slot in the proxy.
    /* solhint-disable-next-line var-name-mixedcase */
    mapping(uint256 => mapping(address => uint256))
        private __removed_epochTxnCount;

    /// @notice Bootstrap.sol contract for auto role multiplier
    /// @dev V2: Set via reinitializeV2(). Used in _computeEpochWeights
    ///      to auto-derive gateway bonus from Bootstrap nodeType.
    ///      Gateway nodes (type 0) get 1.5x, others get 1.0x.
    address public bootstrapContract;

    /// @notice Minimum OmniCore stake required for reward eligibility
    /// @dev V2: Prevents Sybil attacks by requiring economic stake.
    ///      H-01 fix: Defaults to 1,000,000 XOM (18 decimals) at
    ///      deployment for Sybil protection. Seed validators bypass
    ///      via stakeExempt mapping. Adjustable by admin.
    uint256 public minStakeForRewards;

    /// @notice Pending admin address for two-step admin transfer
    /// @dev V2: Set by proposeAdminTransfer(), claimed by acceptAdminTransfer()
    address public pendingAdmin;

    /// @notice Timestamp after which pending admin transfer can be accepted
    /// @dev V2: Must wait ADMIN_TRANSFER_DELAY (48h) after proposal
    uint256 public adminTransferEta;

    /// @notice Addresses exempt from minStakeForRewards check
    /// @dev V2: Allows seed validators (admin-run infrastructure
    ///      nodes) to earn rewards without OmniCore stake. Admin
    ///      can remove exemptions once validators stake normally.
    mapping(address => bool) public stakeExempt;

    /// @notice Address of the admin who proposed the transfer (M-01 R6)
    /// @dev Stored so acceptAdminTransfer can atomically revoke the
    ///      old admin's role. Without this, the old admin retains
    ///      DEFAULT_ADMIN_ROLE indefinitely after transfer.
    address public adminTransferProposer;

    /// @notice Epoch at which each validator last submitted a heartbeat (M-02 R6)
    /// @dev Used in _computeEpochWeights to verify the validator was active
    ///      at the time of the epoch being processed, not just at block.timestamp.
    ///      Prevents offline validators from submitting a heartbeat and then
    ///      retroactively claiming rewards for historical unprocessed epochs.
    mapping(address => uint256) public lastHeartbeatEpoch;

    /// @notice Cumulative XOM distributed across all epochs
    /// @dev H-01 Round 6: Tracks total rewards distributed to
    ///      prevent over-allocation beyond TOTAL_VALIDATOR_POOL.
    ///      Compared against the pool cap in _distributeRewards.
    uint256 public totalDistributed;

    // ── V3 Storage (Adaptive Validator Cap) ──────────────────────────

    /// @notice Maximum reward per epoch for gateway validators (type 0)
    /// @dev V3: Default 0.3 XOM (3e17 wei). Set via reinitializeV3()
    ///      or setGatewayRewardCap(). Applied in _distributeRewards.
    uint256 public gatewayRewardCap;

    /// @notice Maximum reward per epoch for service/computation nodes
    /// @dev V3: Default 0.2 XOM (2e17 wei). Applies to nodeType 1
    ///      (computation) and nodeType 2 (listing). Set via
    ///      reinitializeV3() or setServiceNodeRewardCap().
    uint256 public serviceNodeRewardCap;

    /// @notice LiquidityOverflowPool address for excess reward routing
    /// @dev V3: Receives overflow from _distributeRewards. Set via
    ///      reinitializeV3() or setOverflowPool().
    address public overflowPool;

    /// @notice Whether overflow routing is enabled
    /// @dev V3: Circuit breaker. When false, overflow stays in contract
    ///      (accumulates for future distribution or manual recovery).
    bool public overflowEnabled;

    /// @notice Cumulative XOM transferred to LiquidityOverflowPool
    /// @dev V3: Monotonically increasing. For monitoring/transparency.
    uint256 public totalOverflowTransferred;

    /// @notice Cross-chain overflow batch trigger (V6; was V3 dust guard)
    /// @dev V3: minimum overflow amount to trigger transfer (dust guard).
    ///      V6: re-purposed as the CROSS-CHAIN BATCH TRIGGER — the 65%
    ///      remote bucket accumulates in {pendingCrossChainOverflow} and
    ///      ONE ICTT message is sent once the accumulator reaches this
    ///      value. At the legacy 0.01 XOM setting the accumulator crosses
    ///      every epoch (per-epoch sends, byte-identical to V4); a raised
    ///      value batches sends to the desired cadence. The L1-pool leg is
    ///      NOT gated by this value in V6 — it is pushed every epoch.
    uint256 public minOverflowTransfer;

    // ── V4 Storage (LP-5 Cross-Chain Overflow, 2-hop ICTT→OFT) ────────

    /// @notice L1 ICTT `ERC20TokenHome` for XOM (bridges to C-Chain).
    /// @dev V4: Set via `setIcttTokenHome()`. Mainnet:
    ///      `0xc0Fb51A663ADeD93983E107C962edAC040E27b2D`. This contract
    ///      pulls XOM via `transferFrom` on `send()`, so the rewards
    ///      contract must approve it for each cross-chain transfer.
    ///      Setting to `address(0)` disables the cross-chain leg —
    ///      `_routeOverflow` then sends 100% to the local L1 pool.
    ///
    ///      Packed with `remoteShareBps` (uint16) into one storage
    ///      slot to keep the V4 storage footprint at 5 slots.
    address public icttTokenHome;

    /// @notice Fraction (basis points) of each epoch's overflow
    ///         routed via ICTT to the C-Chain sender.
    /// @dev V4: Default 0 (disabled). Set via `setRemoteShareBps()` to
    ///      e.g. 6500 to send 65% cross-chain (mirroring
    ///      `DEFAULT_OVERFLOW_WEIGHTS_BPS` sum of remote weights). The
    ///      complement (`BPS_DENOMINATOR - remoteShareBps`) stays at
    ///      the L1 `LiquidityOverflowPool`. Per-chain split BELOW the
    ///      C-Chain hop lives in `OverflowOFTSender` on C-Chain.
    uint16 public remoteShareBps;

    /// @notice Avalanche C-Chain `ERC20TokenRemote` for XOM (the
    ///         destination token-transferrer on the C-Chain side).
    /// @dev V4: Mainnet: `0xAF72f6caF76775DaEAbAf5C82Ce05D97359C8Fa1`
    ///      (BridgedXOM). Required by ICTT's `SendTokensInput`.
    address public cchainRemoteTransferrer;

    /// @notice The `OverflowOFTSender` contract on Avalanche C-Chain.
    /// @dev V4: Receives BridgedXOM via ICTT and dispatches per-chain
    ///      via LayerZero OFT to `OverflowOFTReceiver` instances on
    ///      Ethereum, Arbitrum, Base, Polygon. Set via
    ///      `setCchainSender()`. Setting to `address(0)` disables the
    ///      cross-chain leg.
    address public cchainSender;

    /// @notice Avalanche C-Chain blockchain ID (Teleporter bytes32).
    /// @dev V4: Mainnet:
    ///      `0x0427d4b22a2a78bcddd456742caf91b56badbff985ee19aef14573e7343fd652`.
    ///      Required by ICTT's `SendTokensInput.destinationBlockchainID`.
    bytes32 public cchainBlockchainID;

    /// @notice On-chain committee-attestation activity ledger (VT-18).
    /// @dev When set, the activity component of reward weights and the
    ///      epoch-eligibility gate derive from {ValidatorActivityLedger}'s
    ///      committee-attested epochs instead of the self-submitted
    ///      `submitHeartbeat` signal. Zero (unset) falls back to the legacy
    ///      heartbeat path. Set via `reinitializeV4` (upgrade) or
    ///      {setActivityLedger} (Pioneer deployer-direct).
    address public activityLedger;

    // ── V6 Storage (LP-5 flood fix: batch hop 1) ─────────────────────

    /// @notice Accumulated cross-chain overflow bucket not yet sent via
    ///         ICTT (V6, the overflow-flood fix — Option C).
    /// @dev Each processed epoch's cross-chain bucket
    ///      (`overflow * remoteShareBps / BPS_DENOMINATOR`) is added to
    ///      this accumulator instead of being bridged per-epoch. When the
    ///      accumulator reaches {minOverflowTransfer} (which V6 re-purposes
    ///      as the cross-chain BATCH trigger), ONE ICTT message is sent for
    ///      the whole accumulated amount and the accumulator resets to 0.
    ///      The complement (the L1 `LiquidityOverflowPool` leg) is pushed
    ///      every epoch, unchanged.
    ///
    ///      Excluded from the solvency picture in {_distributeRewards}
    ///      (`availableForRewards`), because the XOM it represents is
    ///      committed to a future cross-chain send — it must not be
    ///      re-distributable as validator rewards while parked here.
    ///
    ///      At the legacy 0.01 XOM threshold the accumulator crosses the
    ///      trigger every epoch (live bucket ≈ 10 XOM ≫ 0.01), so V6's
    ///      behavior is byte-identical to V4's per-epoch send until
    ///      governance raises the threshold.
    uint256 public pendingCrossChainOverflow;

    /// @dev Storage gap for future upgrades.
    ///      V1: 50 slots. V3: 50 - 6 = 44 slots remaining.
    ///      V4: 44 - 4 = 40 slots remaining
    ///      (icttTokenHome+remoteShareBps packed = slot 1,
    ///       cchainRemoteTransferrer = slot 2, cchainSender = slot 3,
    ///       cchainBlockchainID = slot 4).
    ///      V4 (VT-18): 40 - 1 = 39 slots remaining
    ///      (`activityLedger` = slot 1, the committee-attestation source).
    ///      V6: 39 - 1 = 38 slots remaining
    ///      (`pendingCrossChainOverflow` = slot 1, the hop-1 batch
    ///      accumulator).
    ///      ICTT send is not payable + Teleporter primary fee is 0
    ///      (validators self-relay), so no fee reserve is needed.
    uint256[38] private __gap;

    // ══════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Emitted when epoch is processed
    /// @param epoch The epoch number that was processed
    /// @param totalReward Total XOM reward distributed
    /// @param activeValidators Count of active validators
    event EpochProcessed(
        uint256 indexed epoch,
        uint256 indexed totalReward,
        uint256 indexed activeValidators
    );

    /// @notice V5: Emitted when an admin fast-forwards
    ///         `lastProcessedEpoch` with `skipToEpoch`. No reward is
    ///         computed or paid for any epoch in the skipped range.
    /// @param fromEpoch The `lastProcessedEpoch` value before the skip
    /// @param toEpoch The new `lastProcessedEpoch` value
    /// @param admin The `DEFAULT_ADMIN_ROLE` caller who performed the skip
    event EpochSkipped(
        uint256 indexed fromEpoch,
        uint256 indexed toEpoch,
        address indexed admin
    );

    /// @notice Emitted when validator claims rewards
    /// @param validator Address of the claiming validator
    /// @param amount Amount of XOM claimed
    /// @param claimedTotal Cumulative total claimed by validator
    event RewardsClaimed(
        address indexed validator,
        uint256 indexed amount,
        uint256 indexed claimedTotal
    );

    /// @notice Emitted when validator submits heartbeat
    /// @param validator Address of the validator
    /// @param timestamp Block timestamp of the heartbeat
    event ValidatorHeartbeat(
        address indexed validator,
        uint256 indexed timestamp
    );

    /// @notice Emitted when transaction processing is recorded
    /// @param validator Address of the processing validator
    /// @param epoch Epoch in which transactions were recorded
    /// @param count Number of transactions recorded
    event TransactionProcessed(
        address indexed validator,
        uint256 indexed epoch,
        uint256 indexed count
    );

    /// @notice Emitted when contract references are updated
    /// @param xomTokenAddr New XOM token address
    /// @param participationAddr New OmniParticipation address
    /// @param omniCoreAddr New OmniCore address
    event ContractsUpdated(
        address indexed xomTokenAddr,
        address indexed participationAddr,
        address indexed omniCoreAddr
    );

    /// @notice Emitted when reward is distributed to validator
    /// @param validator Address receiving the reward
    /// @param epoch Epoch for which reward was distributed
    /// @param amount Amount of XOM distributed
    /// @param weight Validator's weight used for calculation
    event RewardDistributed(
        address indexed validator,
        uint256 indexed epoch,
        uint256 indexed amount,
        uint256 weight
    );

    /// @notice Emitted when reward distribution fails for a validator
    /// @dev M-01 Round 3 audit fix: emitted when external call to
    ///      OmniParticipation or OmniCore fails during weight calc.
    /// @param validator Address that failed
    /// @param epoch Epoch being processed
    /// @param reason Encoded revert reason (may be empty)
    event RewardDistributionFailed(
        address indexed validator,
        uint256 indexed epoch,
        bytes reason
    );

    /// @notice Emitted when emergency withdrawal occurs
    /// @param token Address of the withdrawn token
    /// @param amount Amount withdrawn
    /// @param recipient Address receiving the tokens
    event EmergencyWithdrawal(
        address indexed token,
        uint256 indexed amount,
        address indexed recipient
    );

    /// @notice Emitted when a contract update is proposed
    /// @param xomTokenAddr Proposed XOM token address
    /// @param participationAddr Proposed participation address
    /// @param omniCoreAddr Proposed OmniCore address
    /// @param effectiveTimestamp When the update can be applied
    event ContractsUpdateProposed(
        address indexed xomTokenAddr,
        address indexed participationAddr,
        address indexed omniCoreAddr,
        uint256 effectiveTimestamp
    );

    /// @notice Emitted when a pending contract update is cancelled
    event ContractsUpdateCancelled();

    /// @notice Emitted when validator set exceeds cap
    /// @param totalValidators Total active validators found
    /// @param processedCount Number actually processed
    event ValidatorSetCapped(
        uint256 indexed totalValidators,
        uint256 indexed processedCount
    );

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    /// @notice Emitted when a UUPS upgrade is proposed
    /// @param newImplementation Proposed implementation address
    /// @param effectiveTimestamp When the upgrade can be executed
    event UpgradeProposed(
        address indexed newImplementation,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when a pending upgrade is cancelled
    event UpgradeCancelled();

    /// @notice Emitted when a validator's reward multiplier is changed
    /// @param validator Address of the penalized/restored validator
    /// @param oldMultiplier Previous multiplier value
    /// @param newMultiplier New multiplier value (0-100)
    /// @param reason Human-readable reason for the change
    event RewardMultiplierChanged(
        address indexed validator,
        uint256 indexed oldMultiplier,
        uint256 indexed newMultiplier,
        string reason
    );

    /// @notice Emitted when a validator's role multiplier is changed
    /// @param validator Address of the validator
    /// @param oldMultiplierBps Previous multiplier in basis points
    /// @param newMultiplierBps New multiplier in basis points
    event RoleMultiplierUpdated(
        address indexed validator,
        uint256 indexed oldMultiplierBps,
        uint256 indexed newMultiplierBps
    );

    /// @notice Emitted when a penalty is applied with an expiration
    /// @param validator Address of the penalized validator
    /// @param multiplier Penalty multiplier (1-99)
    /// @param expiresAt Timestamp when penalty auto-expires
    event PenaltyApplied(
        address indexed validator,
        uint256 indexed multiplier,
        uint256 indexed expiresAt
    );

    /// @notice Emitted when an expired penalty is auto-reset
    /// @param validator Address whose penalty was reset
    event PenaltyExpired(
        address indexed validator
    );

    /// @notice Emitted when a validator's stake exemption changes
    /// @param validator Address of the validator
    /// @param exempt Whether the validator is now exempt
    event StakeExemptionUpdated(
        address indexed validator,
        bool indexed exempt
    );

    /// @notice Emitted when minimum stake for rewards is updated
    /// @param oldAmount Previous minimum stake
    /// @param newAmount New minimum stake
    event MinStakeForRewardsUpdated(
        uint256 indexed oldAmount,
        uint256 indexed newAmount
    );

    /// @notice Emitted when the activity ledger is set (VT-18)
    /// @param oldLedger Previous activity ledger address (zero if unset)
    /// @param newLedger New activity ledger address (zero disables)
    event ActivityLedgerUpdated(
        address indexed oldLedger,
        address indexed newLedger
    );

    /// @notice Emitted when an admin transfer is proposed
    /// @param currentAdmin Address proposing the transfer
    /// @param newAdmin Proposed new admin address
    /// @param effectiveTimestamp When the transfer can be accepted
    event AdminTransferProposed(
        address indexed currentAdmin,
        address indexed newAdmin,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when an admin transfer is accepted
    /// @param oldAdmin Previous admin address
    /// @param newAdmin New admin address
    event AdminTransferAccepted(
        address indexed oldAdmin,
        address indexed newAdmin
    );

    /// @notice Emitted when a pending admin transfer is cancelled
    event AdminTransferCancelled();

    /// @notice Emitted when the validator reward pool is running low
    /// @dev H-01 Round 6: Warns operators when remaining pool
    ///      drops below POOL_LOW_THRESHOLD_BPS (10%) of total.
    /// @param remainingPool XOM remaining in the reward pool
    /// @param totalDistributedSoFar Cumulative XOM distributed
    /// @param percentRemainingBps Remaining pool as basis points
    event PoolRunningLow(
        uint256 indexed remainingPool,
        uint256 indexed totalDistributedSoFar,
        uint256 indexed percentRemainingBps
    );

    /// @notice Emitted when epoch reward is capped due to pool
    ///         depletion
    /// @dev H-01 Round 6: Indicates that the calculated epoch
    ///      reward exceeded available pool balance and was reduced.
    /// @param epoch The affected epoch
    /// @param requestedReward Originally calculated reward
    /// @param actualReward Capped reward after solvency check
    event EpochRewardCapped(
        uint256 indexed epoch,
        uint256 indexed requestedReward,
        uint256 indexed actualReward
    );

    /// @notice V3: Emitted when overflow is routed to LiquidityOverflowPool
    /// @param epoch Epoch that generated the overflow
    /// @param overflowAmount XOM amount sent to overflow pool
    /// @param cumulativeOverflow Running total of all overflow transferred
    event OverflowRouted(
        uint256 indexed epoch,
        uint256 indexed overflowAmount,
        uint256 indexed cumulativeOverflow
    );

    /// @notice V3: Emitted when overflow routing fails (circuit breaker)
    /// @param epoch Epoch that generated the overflow
    /// @param amount Amount that failed to route
    /// @param reason Encoded revert reason
    event OverflowRoutingFailed(
        uint256 indexed epoch,
        uint256 indexed amount,
        bytes reason
    );

    /// @notice V3: Emitted when a reward cap is updated
    /// @param nodeType Node type (0=gateway, 1+=service)
    /// @param oldCap Previous cap value
    /// @param newCap New cap value
    event RewardCapUpdated(
        uint8 indexed nodeType,
        uint256 indexed oldCap,
        uint256 indexed newCap
    );

    /// @notice V3: Emitted when overflow pool address is updated
    /// @param oldPool Previous overflow pool address
    /// @param newPool New overflow pool address
    event OverflowPoolUpdated(
        address indexed oldPool,
        address indexed newPool
    );

    /// @notice V3: Emitted when overflow enabled status changes
    /// @param enabled New enabled status
    event OverflowEnabledUpdated(bool indexed enabled);

    /// @notice V3: Emitted when minimum overflow transfer threshold changes
    /// @param oldAmount Previous threshold
    /// @param newAmount New threshold
    event MinOverflowTransferUpdated(
        uint256 indexed oldAmount,
        uint256 indexed newAmount
    );

    /// @notice V4: Emitted when the L1 ICTT TokenHome reference is
    ///         updated.
    /// @param oldTokenHome Previous TokenHome address.
    /// @param newTokenHome New TokenHome address.
    event IcttTokenHomeUpdated(
        address indexed oldTokenHome,
        address indexed newTokenHome
    );

    /// @notice V4: Emitted when the C-Chain `OverflowOFTSender`
    ///         reference is updated.
    /// @dev Set to `address(0)` to disable the cross-chain leg
    ///      without removing other config.
    /// @param oldSender Previous sender address on C-Chain.
    /// @param newSender New sender address on C-Chain.
    event CchainSenderUpdated(
        address indexed oldSender,
        address indexed newSender
    );

    /// @notice V4: Emitted when the C-Chain `ERC20TokenRemote`
    ///         transferrer reference is updated.
    /// @param oldTransferrer Previous remote transferrer.
    /// @param newTransferrer New remote transferrer.
    event CchainRemoteTransferrerUpdated(
        address indexed oldTransferrer,
        address indexed newTransferrer
    );

    /// @notice V4: Emitted when the C-Chain Teleporter blockchain ID
    ///         is updated.
    /// @param oldId Previous blockchain ID.
    /// @param newId New blockchain ID.
    event CchainBlockchainIDUpdated(
        bytes32 indexed oldId,
        bytes32 indexed newId
    );

    /// @notice V4: Emitted when the remote-share fraction is updated.
    /// @param oldBps Previous bps.
    /// @param newBps New bps.
    event RemoteShareBpsUpdated(
        uint16 indexed oldBps,
        uint16 indexed newBps
    );

    /// @notice V4: Emitted when the cross-chain bucket is successfully
    ///         sent via ICTT to the C-Chain `OverflowOFTSender`.
    /// @param epoch Epoch the overflow originated in.
    /// @param amount XOM bridged to C-Chain.
    event CrossChainOverflowSent(
        uint256 indexed epoch,
        uint256 indexed amount
    );

    /// @notice V4: Emitted when the cross-chain bucket is skipped
    ///         because the path is not fully configured (any of:
    ///         `icttTokenHome`/`cchainSender`/`cchainRemoteTransferrer`/
    ///         `cchainBlockchainID` unset).
    /// @dev The skipped bucket is added to the L1 local share rather
    ///      than being lost.
    /// @param epoch Epoch the overflow originated in.
    /// @param amount XOM amount that would have been bridged.
    event CrossChainOverflowSkipped(
        uint256 indexed epoch,
        uint256 indexed amount
    );

    // ══════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Caller is not a validator
    error NotValidator();

    /// @notice No rewards to claim
    error NoRewardsToClaim();

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Epoch must be processed sequentially
    error EpochNotSequential();

    /// @notice Future epoch cannot be processed
    error FutureEpoch();

    /// @notice Insufficient contract balance
    error InsufficientBalance();

    /// @notice Thrown when batch size exceeds maximum
    error BatchTooLarge();

    /// @notice Thrown when timelock has not elapsed
    error TimelockNotElapsed();

    /// @notice Thrown when no pending update exists
    error NoPendingUpdate();

    /// @notice Thrown when staking lock has expired
    error StakeLockExpired();

    /// @notice Thrown when validator set exceeds cap
    error TooManyValidators();

    /// @notice Thrown when contract is ossified and upgrade attempted
    error ContractIsOssified();

    /// @notice Thrown when upgrade target has no deployed code
    error InvalidImplementation();

    /// @notice Thrown when upgrade was not proposed or does not match
    /// @param proposed The proposed implementation address
    /// @param attempted The attempted implementation address
    error UpgradeNotProposed(
        address proposed,
        address attempted
    );

    /// @notice Thrown when reward multiplier exceeds 100
    error MultiplierTooHigh();

    /// @notice Thrown when role multiplier exceeds MAX_ROLE_MULTIPLIER
    error RoleMultiplierTooHigh();

    /// @notice Thrown when reward multiplier is below base (1-9999)
    /// @dev Audit L-02 Round 4: Values 1-9999 for roleMultiplier
    ///      silently reduce rewards. Must be 0 (default) or >= 10000.
    error MultiplierBelowBase();

    /// @notice Thrown when per-epoch per-validator txn cap exceeded
    /// @dev Audit M-04 Round 4
    error TxnCapExceeded();

    /// @notice Thrown when trying to withdraw XOM via emergency
    /// @dev Audit H-01 Round 4: checks both current and original
    error CannotWithdrawXOM();

    /// @notice Thrown when admin transfer conditions are not met
    error AdminTransferNotReady();

    /// @notice Thrown when caller is not the pending admin
    error NotPendingAdmin();

    /// @notice V3: Reward cap cannot be zero
    error ZeroCap();

    /// @notice V3: Zero amount not allowed
    error ZeroAmount();

    /// @notice V3: Overflow pool not configured
    error OverflowPoolNotSet();

    /// @notice V4: A remote-share-bps value exceeds `BPS_DENOMINATOR`.
    error RemoteShareBpsTooHigh();

    /// @notice V5: `skipToEpoch` target is not strictly greater than
    ///         `lastProcessedEpoch` — the function only ever moves
    ///         forward.
    error CannotSkipBackward();

    /// @notice V5: `unpause` was called while more than
    ///         {MAX_UNSKIPPED_PENDING_EPOCHS} epochs are pending and
    ///         un-skipped. Call {skipToEpoch} first (to forgive the
    ///         backlog) or process it for real, then unpause.
    error PendingBacklogTooLarge(
        uint256 pending, uint256 maxAllowed
    );

    /// @notice V5: an admin-supplied address that must reference a
    ///         same-chain contract has no code. Only checked for
    ///         addresses this contract can actually verify — i.e.
    ///         NOT the C-Chain-side cross-chain addresses, which this
    ///         L1 contract has no way to inspect.
    error NotAContract(address target);

    // ══════════════════════════════════════════════════════════════════
    //                           INITIALIZATION
    // ══════════════════════════════════════════════════════════════════

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
     * @notice Initialize the contract
     * @dev Called once during proxy deployment. Sets up roles,
     *      external contract references, and genesis timestamp.
     * @param xomTokenAddr Address of XOM token contract
     * @param participationAddr Address of OmniParticipation
     * @param omniCoreAddr Address of OmniCore contract
     */
    function initialize(
        address xomTokenAddr,
        address participationAddr,
        address omniCoreAddr
    ) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BLOCKCHAIN_ROLE, msg.sender);
        _grantRole(ROLE_MANAGER_ROLE, msg.sender);

        if (xomTokenAddr == address(0)) revert ZeroAddress();
        if (participationAddr == address(0)) {
            revert ZeroAddress();
        }
        if (omniCoreAddr == address(0)) revert ZeroAddress();

        xomToken = IERC20(xomTokenAddr);
        participation =
            IOmniParticipation(participationAddr);
        omniCore = IOmniCore(omniCoreAddr);

        // H-01 Round 4: Store original XOM address to prevent
        // emergencyWithdraw bypass via contract reference swap
        _originalXomToken = xomTokenAddr;

        // solhint-disable-next-line not-rely-on-time
        genesisTimestamp = block.timestamp;
        lastProcessedEpoch = 0;
        totalBlocksProduced = 0;
        totalOutstandingRewards = 0;
    }

    /**
     * @notice V2 initializer — sets Bootstrap.sol contract reference
     * @dev Called once via upgradeToAndCall() to set the bootstrap
     *      contract for auto role multiplier derivation. Gateway nodes
     *      (type 0) automatically get 1.5x; computation nodes (type 1)
     *      get 1.0x. Manual setRoleMultiplier() overrides still work.
     *      H-01 fix: minStakeForRewards defaults to 1M XOM (not 0)
     *      for Sybil protection from deployment. Seed validators
     *      must be added to stakeExempt mapping separately.
     * @param _bootstrap Address of the Bootstrap.sol contract on L1
     */
    function reinitializeV2(
        address _bootstrap
    ) external onlyRole(DEFAULT_ADMIN_ROLE) reinitializer(2) {
        if (_bootstrap == address(0)) revert ZeroAddress();
        bootstrapContract = _bootstrap;
        // H-01 fix: Default to 1M XOM (18 decimals) for Sybil
        // protection from deployment. Seed validators use
        // stakeExempt mapping to bypass this requirement.
        minStakeForRewards = 1_000_000 ether;
    }

    /**
     * @notice V3 initializer — Adaptive Validator Cap with overflow
     * @dev Called once via upgradeToAndCall() to set per-node-type
     *      reward caps and configure the LiquidityOverflowPool.
     *      Gateway cap: 0.3 XOM/epoch, Service node cap: 0.2 XOM/epoch.
     *      Overflow routing starts DISABLED — admin must enable after
     *      verifying pool configuration.
     * @param _overflowPool Address of LiquidityOverflowPool proxy
     */
    function reinitializeV3(
        address _overflowPool
    ) external onlyRole(DEFAULT_ADMIN_ROLE) reinitializer(3) {
        if (_overflowPool == address(0)) revert ZeroAddress();

        gatewayRewardCap = 300_000_000_000_000_000; // 0.3 ether
        serviceNodeRewardCap = 200_000_000_000_000_000; // 0.2 ether
        overflowPool = _overflowPool;
        overflowEnabled = false; // Admin enables after pool setup
        minOverflowTransfer = 10_000_000_000_000_000; // 0.01 ether
    }

    /**
     * @notice V4 initializer — committee-attestation activity ledger (VT-18)
     * @dev Called once via upgradeToAndCall() to point the rewards contract at
     *      the {ValidatorActivityLedger}. From this point the activity
     *      component and the epoch-eligibility gate derive from committee-
     *      attested epochs instead of self-submitted heartbeats. Passing zero
     *      (or omitting this initializer) keeps the legacy heartbeat fallback.
     * @param _activityLedger Address of the ValidatorActivityLedger contract,
     *        or zero to keep the heartbeat fallback active.
     */
    function reinitializeV4(
        address _activityLedger
    ) external onlyRole(DEFAULT_ADMIN_ROLE) reinitializer(4) {
        address old = activityLedger;
        activityLedger = _activityLedger;
        emit ActivityLedgerUpdated(old, _activityLedger);
    }

    /**
     * @notice V6 initializer — hop-1 batch trigger + node-type caps restore
     * @dev Called once via upgradeToAndCall() as part of the V6 upgrade.
     *      Two changes land atomically at apply:
     *
     *      1. `minOverflowTransfer` becomes the cross-chain BATCH trigger:
     *         `_routeOverflow` accumulates the 65% remote bucket in
     *         {pendingCrossChainOverflow} and sends ONE ICTT message when
     *         the accumulator reaches this value (see the storage-layout
     *         comment). Passing the calibrated threshold here — instead of
     *         a second `setMinOverflowTransfer` governance round — is what
     *         makes the per-epoch cross-chain message flood stop AT APPLY.
     *         The legacy 0.01 XOM value keeps V4's per-epoch behavior.
     *
     *      2. `bootstrapContract` is re-pointed at the live Bootstrap.sol
     *         registry (mainnet `0xB7317dF915464eD08b287843b67cD750966e79F8`),
     *         restoring per-node-type reward caps: active gateway nodes
     *         (nodeType 0) resolve to {gatewayRewardCap}, and
     *         listing/service nodes (nodeType 1/2) resolve to
     *         {serviceNodeRewardCap}. The live proxy has held
     *         `bootstrapContract == address(0)` since ~block 459,000,
     *         silently routing EVERY validator to the 1-wei service cap
     *         (full-emission overflow). Caps and the VT-18 committee-
     *         attestation activity gate are separate mechanisms — this
     *         change touches only the per-node-type cap resolution.
     *
     * @param _bootstrapContract Address of the live Bootstrap.sol registry
     *        that provides `isNodeActive(address) → (bool, uint8)`.
     * @param _minOverflowTransfer New cross-chain batch trigger in XOM
     *        (18 decimals). Must be non-zero.
     */
    function reinitializeV5(
        address _bootstrapContract,
        uint256 _minOverflowTransfer
    ) external onlyRole(DEFAULT_ADMIN_ROLE) reinitializer(5) {
        if (_bootstrapContract == address(0)) revert ZeroAddress();
        if (_bootstrapContract.code.length == 0) {
            revert NotAContract(_bootstrapContract);
        }
        if (_minOverflowTransfer == 0) revert ZeroAmount();

        bootstrapContract = _bootstrapContract;

        uint256 oldMin = minOverflowTransfer;
        minOverflowTransfer = _minOverflowTransfer;

        // Fresh V6 slot (reads 0 by default); zeroing it explicitly makes
        // the intent auditable: the upgrade starts with an empty batch.
        pendingCrossChainOverflow = 0;

        emit MinOverflowTransferUpdated(oldMin, _minOverflowTransfer);
    }

    // ══════════════════════════════════════════════════════════════════
    //                       EXTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Submit validator heartbeat (DEPRECATED — VT-18 no-op)
     * @dev VT-18: the activity component of reward weights is now derived from
     *      the on-chain committee-attestation ledger ({activityLedger}), not
     *      from a self-submitted heartbeat. This entry point is retained for
     *      ABI compatibility and preserves the `whenNotPaused` + `NotValidator`
     *      guards, but writes no storage — a validator can no longer
     *      manufacture its own "active" status by calling this function.
     */
    function submitHeartbeat() external whenNotPaused {
        address caller = _msgSender();
        if (!omniCore.isValidator(caller)) {
            revert NotValidator();
        }
        // Intentionally no storage writes: activity is attested on chain by
        // the M-of-N committee, not self-reported here.
        /* solhint-disable not-rely-on-time */
        emit ValidatorHeartbeat(
            caller, block.timestamp
        );
        /* solhint-enable not-rely-on-time */
    }

    /**
     * @notice Record transaction processing by validator
     * @dev Called by BLOCKCHAIN_ROLE when validator processes
     *      a transaction. M-04 Round 4: Per-epoch per-validator
     *      cap prevents BLOCKCHAIN_ROLE from inflating any
     *      single validator's transaction count.
     * @param validator Address of processing validator
     */
    function recordTransactionProcessing(
        address validator
    ) external onlyRole(BLOCKCHAIN_ROLE) {
        if (!omniCore.isValidator(validator)) {
            revert NotValidator();
        }

        uint256 currentEpoch = getCurrentEpoch();
        // M-04 Round 4: Per-epoch per-validator txn cap
        // M-01 Round 7: Use transactionsProcessed directly
        // (removed redundant _epochTxnCount mapping)
        if (
            transactionsProcessed[validator][currentEpoch]
                > MAX_TXN_PER_EPOCH_PER_VALIDATOR - 1
        ) {
            revert TxnCapExceeded();
        }

        ++transactionsProcessed[validator][currentEpoch];
        ++epochTotalTransactions[currentEpoch];

        emit TransactionProcessed(
            validator, currentEpoch, 1
        );
    }

    /**
     * @notice Record multiple transaction processing
     * @dev Capped at MAX_TX_BATCH (1000) per call to prevent
     *      unbounded gas consumption. M-04 Round 4: Also
     *      enforces per-epoch per-validator cap.
     * @param validator Address of processing validator
     * @param count Number of transactions processed
     */
    function recordMultipleTransactions(
        address validator,
        uint256 count
    ) external onlyRole(BLOCKCHAIN_ROLE) {
        if (count == 0 || count > MAX_TX_BATCH) {
            revert BatchTooLarge();
        }
        if (!omniCore.isValidator(validator)) {
            revert NotValidator();
        }

        uint256 currentEpoch = getCurrentEpoch();
        // M-04 Round 4: Per-epoch per-validator txn cap
        // M-01 Round 7: Use transactionsProcessed directly
        // (removed redundant _epochTxnCount mapping)
        uint256 current =
            transactionsProcessed[validator][currentEpoch];
        if (
            current + count
                > MAX_TXN_PER_EPOCH_PER_VALIDATOR
        ) {
            revert TxnCapExceeded();
        }

        transactionsProcessed[validator][currentEpoch] =
            current + count;
        epochTotalTransactions[currentEpoch] += count;

        emit TransactionProcessed(
            validator, currentEpoch, count
        );
    }

    /**
     * @notice Process epoch and distribute rewards
     * @dev Epochs MUST be processed sequentially to prevent
     *      reward destruction via epoch skipping.
     *      V2: Permissionless — any caller can process epochs.
     *      Sequential epoch enforcement (lastProcessedEpoch + 1)
     *      prevents double-processing. All nodes race to call;
     *      losers revert with EpochNotSequential (no harm done).
     * @param epoch Epoch number to process
     */
    function processEpoch(
        uint256 epoch
    )
        external
        nonReentrant
        whenNotPaused
    {
        uint256 currentEpoch = getCurrentEpoch();
        if (epoch != lastProcessedEpoch + 1) {
            revert EpochNotSequential();
        }
        if (epoch > currentEpoch) revert FutureEpoch();

        // M-02: Use epoch-based reward to prevent emission
        // desynchronization when epochs are processed late
        uint256 epochReward =
            calculateBlockRewardForEpoch(epoch);

        // Get active nodes (validators)
        address[] memory validators =
            omniCore.getActiveNodes();

        // M-02 Round 4: Reset expired penalties
        _resetExpiredPenalties(validators);

        // Count and distribute in single pass
        (
            uint256 activeCount,
            uint256[] memory weights,
            uint256 totalWeight
        ) = _computeEpochWeights(validators, epoch);

        if (activeCount == 0) {
            // No active validators, skip distribution
            lastProcessedEpoch = epoch;
            ++totalBlocksProduced;
            return;
        }

        // Distribute rewards proportionally
        _distributeRewards(
            validators,
            weights,
            totalWeight,
            epochReward,
            epoch
        );

        // Update state
        lastProcessedEpoch = epoch;
        ++totalBlocksProduced;
        epochActiveValidators[epoch] = activeCount;

        emit EpochProcessed(
            epoch, epochReward, activeCount
        );
    }

    /**
     * @notice Process multiple epochs at once
     * @dev Gas-optimized batch processing. Epochs are
     *      processed sequentially starting from
     *      lastProcessedEpoch + 1. Validator list is
     *      cached outside the loop (H-03 fix).
     *      V2: Permissionless — any caller can process.
     *      Sequential epoch enforcement prevents double-processing.
     *      Capped at MAX_BATCH_EPOCHS (50 = 100 seconds
     *      of catch-up) to limit gas and reduce stale-state
     *      drift when processing historical epochs with
     *      current state (M-03 fix).
     *
     *      M-03 Round 4: Stale validator state during batch
     *      processing is accepted behavior. The staleness
     *      window is bounded to 100 seconds (50 epochs x 2s
     *      blocks), which is negligible for weight calculation
     *      accuracy. Validator heartbeats, stakes, and
     *      participation scores change slowly relative to
     *      this window.
     *
     *      L-03 Round 4: Memory allocation for getActiveNodes()
     *      is uncapped but processing is capped at
     *      MAX_VALIDATORS_PER_EPOCH (200). The memory cost is
     *      O(n) where n = total validators, which is bounded
     *      by the on-chain validator registration limit.
     *
     *      L-01 Round 4: Rounding dust from integer division
     *      in _distributeRewards is a known acceptable behavior.
     *      The dust is negligible (< 1 wei per validator per
     *      epoch) and accumulates in the contract as surplus
     *      balance, improving solvency over time.
     *
     * @param count Number of epochs to process
     */
    function processMultipleEpochs(
        uint256 count
    )
        external
        nonReentrant
        whenNotPaused
    {
        // M-03: Cap batch size to limit state drift
        if (count > MAX_BATCH_EPOCHS) {
            revert BatchTooLarge();
        }

        uint256 currentEpoch = getCurrentEpoch();
        uint256 nextEpoch;

        // H-03: Cache validator list outside loop
        address[] memory validators =
            omniCore.getActiveNodes();

        if (validators.length > MAX_VALIDATORS_PER_EPOCH) {
            emit ValidatorSetCapped(
                validators.length,
                MAX_VALIDATORS_PER_EPOCH
            );
        }

        // M-02 Round 4: Reset expired penalties once per batch
        _resetExpiredPenalties(validators);

        for (uint256 i = 0; i < count;) {
            nextEpoch = lastProcessedEpoch + 1;
            if (nextEpoch > currentEpoch) break;

            // M-02: Use epoch-based reward calculation
            uint256 epochReward =
                calculateBlockRewardForEpoch(nextEpoch);

            (
                uint256 activeCount,
                uint256[] memory weights,
                uint256 totalWeight
            ) = _computeEpochWeights(
                validators, nextEpoch
            );

            if (activeCount > 0) {
                _distributeRewards(
                    validators,
                    weights,
                    totalWeight,
                    epochReward,
                    nextEpoch
                );
                epochActiveValidators[nextEpoch] =
                    activeCount;
            }

            lastProcessedEpoch = nextEpoch;
            ++totalBlocksProduced;

            emit EpochProcessed(
                nextEpoch, epochReward, activeCount
            );

            unchecked { ++i; }
        }
    }

    /**
     * @notice Claim accumulated validator rewards
     * @dev Transfers all accumulated XOM to caller.
     *      No active-validator check: rewards earned during
     *      active period are claimable after deactivation
     *      (H-04 fix).
     *      Updates totalOutstandingRewards for solvency
     *      tracking (M-02 Round 3 fix).
     *      M-05 Round 4: Removed whenNotPaused. Rewards are
     *      already earned; claiming is a withdrawal that should
     *      always be available even during emergency pauses.
     */
    function claimRewards()
        external
        nonReentrant
    {
        address caller = _msgSender();
        uint256 amount = accumulatedRewards[caller];
        if (amount == 0) revert NoRewardsToClaim();

        // Check contract balance
        uint256 balance = xomToken.balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();

        // Update state before transfer (CEI pattern)
        accumulatedRewards[caller] = 0;
        totalClaimed[caller] += amount;
        totalOutstandingRewards -= amount;

        // Transfer rewards
        xomToken.safeTransfer(caller, amount);

        emit RewardsClaimed(
            caller, amount, totalClaimed[caller]
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Propose new contract references (48h timelock)
     * @dev Changes are not applied immediately. After the
     *      timelock elapses, call applyContracts() to finalize.
     *      V5 fix: also rejects an address with no code — all three
     *      are same-chain (L1) contract references, so `code.length`
     *      is a real, checkable guarantee here (unlike the C-Chain
     *      cross-chain setters below, which this contract cannot
     *      inspect). Without this, a typo'd EOA reference would only
     *      surface later as an unrelated revert deep in `_computeEpochWeights`
     *      or `_distributeRewards`.
     * @param xomTokenAddr New XOM token address
     * @param participationAddr New OmniParticipation address
     * @param omniCoreAddr New OmniCore address
     */
    function proposeContracts(
        address xomTokenAddr,
        address participationAddr,
        address omniCoreAddr
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (xomTokenAddr == address(0)) revert ZeroAddress();
        if (participationAddr == address(0)) {
            revert ZeroAddress();
        }
        if (omniCoreAddr == address(0)) revert ZeroAddress();
        if (xomTokenAddr.code.length == 0) {
            revert NotAContract(xomTokenAddr);
        }
        if (participationAddr.code.length == 0) {
            revert NotAContract(participationAddr);
        }
        if (omniCoreAddr.code.length == 0) {
            revert NotAContract(omniCoreAddr);
        }

        /* solhint-disable not-rely-on-time */
        uint256 effective = block.timestamp
            + CONTRACT_UPDATE_DELAY;
        /* solhint-enable not-rely-on-time */

        pendingContracts = PendingContractsUpdate({
            xomToken: xomTokenAddr,
            participation: participationAddr,
            omniCore: omniCoreAddr,
            effectiveTimestamp: effective
        });

        emit ContractsUpdateProposed(
            xomTokenAddr,
            participationAddr,
            omniCoreAddr,
            effective
        );
    }

    /**
     * @notice Apply pending contract references after timelock
     * @dev Reverts if timelock has not elapsed or no pending
     *      update exists.
     */
    function applyContracts()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        PendingContractsUpdate memory pending =
            pendingContracts;

        if (pending.effectiveTimestamp == 0) {
            revert NoPendingUpdate();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < pending.effectiveTimestamp) {
            revert TimelockNotElapsed();
        }

        xomToken = IERC20(pending.xomToken);
        participation =
            IOmniParticipation(pending.participation);
        omniCore = IOmniCore(pending.omniCore);

        // Clear pending state
        delete pendingContracts;

        emit ContractsUpdated(
            pending.xomToken,
            pending.participation,
            pending.omniCore
        );
    }

    /**
     * @notice Cancel a pending contract reference update
     * @dev Can be called at any time before applyContracts().
     */
    function cancelContractsUpdate()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingContracts.effectiveTimestamp == 0) {
            revert NoPendingUpdate();
        }
        delete pendingContracts;
        emit ContractsUpdateCancelled();
    }

    /**
     * @notice Propose a UUPS upgrade (48h timelock)
     * @dev H-01 Round 3 audit fix: upgrades cannot be executed
     *      immediately. The admin must propose the new
     *      implementation, wait UPGRADE_DELAY (48h), then
     *      call upgradeToAndCall(). The _authorizeUpgrade()
     *      function verifies that the proposed implementation
     *      matches and the timelock has elapsed.
     *      MUST be combined with a multisig wallet for production.
     * @param newImplementation Address of proposed implementation
     */
    function proposeUpgrade(
        address newImplementation
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
        if (newImplementation == address(0)) {
            revert ZeroAddress();
        }
        if (newImplementation.code.length == 0) {
            revert InvalidImplementation();
        }

        /* solhint-disable not-rely-on-time */
        uint256 effective = block.timestamp + UPGRADE_DELAY;
        /* solhint-enable not-rely-on-time */

        pendingUpgrade = PendingUpgrade({
            newImplementation: newImplementation,
            effectiveTimestamp: effective
        });

        emit UpgradeProposed(newImplementation, effective);
    }

    /**
     * @notice Cancel a pending upgrade proposal
     * @dev Can be called at any time before the upgrade is executed.
     */
    function cancelUpgrade()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingUpgrade.effectiveTimestamp == 0) {
            revert NoPendingUpdate();
        }
        delete pendingUpgrade;
        emit UpgradeCancelled();
    }

    /**
     * @notice Emergency withdraw stuck tokens (non-XOM only)
     * @dev Cannot withdraw XOM to prevent draining validator
     *      rewards. H-01 Round 4: checks both current xomToken
     *      AND _originalXomToken to prevent bypass via
     *      proposeContracts/applyContracts swapping xomToken
     *      to a different address.
     *      SECURITY: Admin MUST be a multi-sig wallet with
     *      timelock.
     * @param token Token address to withdraw (must NOT be XOM)
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     */
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        // H-01 Round 4: Check both current and original XOM
        if (
            token == address(xomToken)
                || token == _originalXomToken
        ) {
            revert CannotWithdrawXOM();
        }
        IERC20(token).safeTransfer(recipient, amount);
        emit EmergencyWithdrawal(token, amount, recipient);
    }

    /**
     * @notice Set reward multiplier for a validator
     * @dev Called by PENALTY_ROLE to penalize or restore validators.
     *      A multiplier of 0 is treated as 100% (default/full rewards).
     *      Values 1-100 set the explicit reward percentage.
     *      Setting to 1 effectively zeroes rewards (1% of normal).
     *      M-02 Round 4: Penalty multipliers below 100 (i.e. penalties)
     *      auto-expire after MAX_PENALTY_DURATION (30 days). Setting
     *      multiplier to 0 or 100 (restoring) clears the expiry.
     * @param validator Address of the validator
     * @param multiplier Reward percentage (0=default/100%, 1-100)
     * @param reason Human-readable reason for the change
     */
    function setRewardMultiplier(
        address validator,
        uint256 multiplier,
        string calldata reason
    ) external onlyRole(PENALTY_ROLE) {
        if (multiplier > 100) revert MultiplierTooHigh();

        uint256 oldMultiplier = rewardMultiplier[validator];
        rewardMultiplier[validator] = multiplier;

        // M-02 Round 4: Set penalty expiration for actual penalties
        if (multiplier != 0 && multiplier < 100) {
            // solhint-disable-next-line not-rely-on-time
            uint256 expiry = block.timestamp
                + MAX_PENALTY_DURATION;
            penaltyExpiresAt[validator] = expiry;
            emit PenaltyApplied(validator, multiplier, expiry);
        } else {
            // Restoring to default or full — clear expiry
            delete penaltyExpiresAt[validator];
        }

        emit RewardMultiplierChanged(
            validator,
            oldMultiplier,
            multiplier,
            reason
        );
    }

    /**
     * @notice Set role-based reward multiplier for a validator
     * @dev Gateway validators should be set to 15000 (1.5x) to
     *      compensate for higher operational costs (AVAX staking,
     *      avalanchego infrastructure). Service nodes default to
     *      10000 (1.0x). The bonus only applies when the validator
     *      has an active heartbeat (heartbeat score > 0), preventing
     *      offline nodes from earning the gateway premium.
     *      M-01 Round 4: Max capped to MAX_ROLE_MULTIPLIER (1.5x).
     *      L-02 Round 4: Values 1-9999 rejected (silent no-ops that
     *      would reduce rewards). Must be 0 (default) or >= 10000.
     * @param validator Address of the validator
     * @param multiplierBps Multiplier in basis points (10000 = 1.0x)
     */
    function setRoleMultiplier(
        address validator,
        uint256 multiplierBps
    ) external onlyRole(ROLE_MANAGER_ROLE) {
        if (multiplierBps > MAX_ROLE_MULTIPLIER) {
            revert RoleMultiplierTooHigh();
        }
        // L-02: Reject sub-base values (1-9999) which silently
        // reduce rewards — must be 0 (default) or >= 10000
        if (
            multiplierBps != 0 && multiplierBps < 10000
        ) {
            revert MultiplierBelowBase();
        }

        uint256 oldMultiplier = roleMultiplier[validator];
        roleMultiplier[validator] = multiplierBps;

        emit RoleMultiplierUpdated(
            validator, oldMultiplier, multiplierBps
        );
    }

    /**
     * @notice Pause all operations
     * @dev Only DEFAULT_ADMIN_ROLE can pause. Blocks epoch
     *      processing, heartbeats, claims, and recording.
     */
    function pause()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _pause();
    }

    /**
     * @notice Unpause operations
     * @dev Only DEFAULT_ADMIN_ROLE can unpause. Resumes
     *      normal contract operation after emergency.
     *
     *      V5: reverts if more than {MAX_UNSKIPPED_PENDING_EPOCHS}
     *      epochs are pending and un-skipped. Without this, an admin
     *      who forgets to call {skipToEpoch} before unpausing a
     *      long-paused contract would instantly make the ENTIRE
     *      backlog payable — {processEpoch}/{processMultipleEpochs}
     *      are permissionless, so any caller could claim real rewards
     *      for it in the very next transaction, with no way to undo
     *      it by re-pausing. This guard forces that to be an explicit
     *      choice (skip the backlog, or process it for real) rather
     *      than an ordering mistake. Skipped once ossified: {skipToEpoch}
     *      is itself blocked post-ossification (see its own guard), so
     *      requiring it first would permanently lock `unpause` instead
     *      of protecting anything.
     */
    function unpause()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!_ossified) {
            uint256 currentEpoch = getCurrentEpoch();
            // solhint-disable-next-line gas-strict-inequalities
            uint256 pending = currentEpoch <= lastProcessedEpoch
                ? 0
                : currentEpoch - lastProcessedEpoch;
            if (pending > MAX_UNSKIPPED_PENDING_EPOCHS) {
                revert PendingBacklogTooLarge(
                    pending, MAX_UNSKIPPED_PENDING_EPOCHS
                );
            }
        }
        _unpause();
    }

    /**
     * @notice V5: Fast-forward `lastProcessedEpoch`, computing and
     *         paying NO reward for any epoch in the skipped range
     * @dev Founder-settled policy (2026-07-04): when validator rewards
     *      are unpaused after an extended pause, the epochs missed
     *      during the pause are NOT back-paid. Before this function,
     *      the only way to advance `lastProcessedEpoch` was
     *      {processEpoch}/{processMultipleEpochs}, both of which
     *      compute and distribute a real reward for every epoch they
     *      step through — calling either one enough times to reach the
     *      present would BE the forbidden catch-up payout. This
     *      function touches no reward-related state and moves only
     *      `lastProcessedEpoch`.
     *
     *      Restricted to `whenPaused` so it cannot race a concurrent
     *      {processEpoch} call, and only ever moves forward, so it
     *      cannot be used to replay or rewind already-processed
     *      history. {getPendingEpochs} and {getCurrentEpoch} are
     *      unaffected by this change other than through
     *      `lastProcessedEpoch` itself.
     *
     *      V5 fix: blocked once {ossify} has been called. {ossify}'s
     *      own NatSpec documents that only epoch processing,
     *      heartbeats, claims, and pause/unpause survive
     *      ossification — this reward-shaping capability must not be
     *      a silent sixth exception to that promise.
     * @param targetEpoch The epoch to fast-forward to. Must be
     *        strictly greater than the current `lastProcessedEpoch`
     *        and must not exceed the current real epoch.
     */
    function skipToEpoch(
        uint256 targetEpoch
    ) external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
        if (_ossified) revert ContractIsOssified();
        // solhint-disable-next-line gas-strict-inequalities
        if (targetEpoch <= lastProcessedEpoch) {
            revert CannotSkipBackward();
        }
        if (targetEpoch > getCurrentEpoch()) {
            revert FutureEpoch();
        }

        uint256 fromEpoch = lastProcessedEpoch;
        lastProcessedEpoch = targetEpoch;

        // V5 fix: _msgSender(), not raw msg.sender — this event is the
        // on-chain audit trail for who performed the skip; a relayed
        // call would otherwise log the trusted forwarder's address.
        emit EpochSkipped(fromEpoch, targetEpoch, _msgSender());
    }

    /**
     * @notice Permanently remove upgrade capability
     * @dev One-way, irreversible. Can only be called by admin
     *      (through timelock). Once ossified, the contract can
     *      never be upgraded again.
     *
     *      Planned Timeline (M-04 audit recommendation):
     *        - Deploy to mainnet
     *        - 6-month minimum tuning period
     *        - Governance vote to approve ossification
     *        - Admin calls ossify()
     *        - Post-ossification: only epoch processing,
     *          heartbeats, claims, and pause/unpause continue
     */
    function ossify()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _ossified = true;
        // Clear any pending upgrade
        delete pendingUpgrade;
        emit ContractOssified(address(this));
    }

    /**
     * @notice Transfer admin authority over BLOCKCHAIN_ROLE to a new admin role
     * @dev One-time admin call to delegate BLOCKCHAIN_ROLE management to
     *      ValidatorProvisioner (via PROVISIONER_ROLE). After this call,
     *      only holders of newAdminRole can grant/revoke BLOCKCHAIN_ROLE.
     *      DEFAULT_ADMIN_ROLE can no longer grant/revoke BLOCKCHAIN_ROLE directly.
     * @param newAdminRole The role that will become admin of BLOCKCHAIN_ROLE
     */
    function setBlockchainRoleAdmin(
        bytes32 newAdminRole
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRoleAdmin(BLOCKCHAIN_ROLE, newAdminRole);
    }

    /**
     * @notice Set minimum OmniCore stake required for reward eligibility
     * @dev V2 H-02 fix: Prevents Sybil attacks by requiring economic
     *      stake. Set to 0 initially (seed validators). Increase to
     *      >= 1,000,000 XOM before public launch.
     * @param amount Minimum stake in XOM (18 decimals). 0 = no minimum.
     */
    function setMinStakeForRewards(
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 old = minStakeForRewards;
        minStakeForRewards = amount;
        emit MinStakeForRewardsUpdated(old, amount);
    }

    /**
     * @notice Set the committee-attestation activity ledger (VT-18)
     * @dev Pioneer deployer-direct setter — no built-in delay. When set to a
     *      non-zero address, the activity component and epoch-eligibility gate
     *      derive from {IActivityLedger} committee-attested epochs instead of
     *      self-submitted heartbeats. Passing zero reverts to the heartbeat
     *      fallback.
     * @param ledger Address of the ValidatorActivityLedger (zero to disable).
     */
    function setActivityLedger(
        address ledger
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address old = activityLedger;
        activityLedger = ledger;
        emit ActivityLedgerUpdated(old, ledger);
    }

    /**
     * @notice Set stake exemption for a validator address
     * @dev V2: Allows seed validators (admin-run nodes) to earn
     *      rewards without meeting minStakeForRewards. Exempt
     *      addresses bypass the stake check in _computeEpochWeights
     *      but still need active heartbeats and Bootstrap registration.
     *      Remove exemptions once validators stake normally.
     * @param validator Address to exempt or un-exempt
     * @param exempt True to exempt, false to require normal staking
     */
    function setStakeExempt(
        address validator,
        bool exempt
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (validator == address(0)) revert ZeroAddress();
        stakeExempt[validator] = exempt;
        emit StakeExemptionUpdated(validator, exempt);
    }

    /**
     * @notice Propose transfer of DEFAULT_ADMIN_ROLE to a new address
     * @dev V2 M-05 fix: Two-step admin transfer with 48h delay.
     *      Step 1: Current admin calls proposeAdminTransfer(newAdmin).
     *      Step 2: After 48h, newAdmin calls acceptAdminTransfer().
     *      Can be cancelled by current admin before acceptance.
     *      V5 fix: uses `_msgSender()`, not raw `msg.sender`, to record
     *      the real proposer — see {acceptAdminTransfer} for why this
     *      matters.
     * @param newAdmin Address to receive admin role
     */
    function proposeAdminTransfer(
        address newAdmin
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin == address(0)) revert ZeroAddress();
        address caller = _msgSender();
        // solhint-disable-next-line not-rely-on-time
        uint256 eta = block.timestamp + ADMIN_TRANSFER_DELAY;
        pendingAdmin = newAdmin;
        adminTransferEta = eta;
        // M-01 R6: Store the proposer so acceptAdminTransfer can
        // atomically revoke their role
        adminTransferProposer = caller;
        emit AdminTransferProposed(caller, newAdmin, eta);
    }

    /**
     * @notice Accept pending admin role transfer
     * @dev Must be called by the pending admin after the delay.
     *      Grants DEFAULT_ADMIN_ROLE to caller and revokes it
     *      from all current admin role holders.
     *      V5 fix: uses `_msgSender()`, not raw `msg.sender`. Raw
     *      `msg.sender` here would compare the FORWARDER's address
     *      against `pendingAdmin` (reverting for a real relayed
     *      accept) and, worse, would record the forwarder as the new
     *      admin to grant/compare against on any future transfer —
     *      `oldAdmin != caller` silently failing to match would make
     *      `_revokeRole` a no-op (OZ's `revokeRole` doesn't revert
     *      when the role isn't held), leaving BOTH the old and new
     *      admin holding `DEFAULT_ADMIN_ROLE` simultaneously — exactly
     *      the failure mode the M-01 R6 atomic-revoke fix exists to
     *      prevent.
     */
    function acceptAdminTransfer() external {
        address caller = _msgSender();
        if (caller != pendingAdmin) revert NotPendingAdmin();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < adminTransferEta) {
            revert AdminTransferNotReady();
        }

        // M-01 R6: Store the old admin (proposer) before clearing state
        address oldAdmin = adminTransferProposer;

        // Clear pending state
        pendingAdmin = address(0);
        adminTransferEta = 0;
        adminTransferProposer = address(0);

        // Grant to new admin first, then revoke from old admin
        _grantRole(DEFAULT_ADMIN_ROLE, caller);
        // M-01 R6: Atomically revoke the old admin's role to prevent
        // both addresses holding DEFAULT_ADMIN_ROLE simultaneously
        if (oldAdmin != address(0) && oldAdmin != caller) {
            _revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin);
        }

        emit AdminTransferAccepted(oldAdmin, caller);
    }

    /**
     * @notice Cancel a pending admin transfer
     * @dev Can only be called by current admin before acceptance.
     */
    function cancelAdminTransfer()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        pendingAdmin = address(0);
        adminTransferEta = 0;
        adminTransferProposer = address(0);
        emit AdminTransferCancelled();
    }

    // ══════════════════════════════════════════════════════════════════
    //                   V3: OVERFLOW ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Set the per-epoch reward cap for gateway validators
     * @dev V3: Gateway nodes (Bootstrap type 0) are capped at this
     *      value per epoch. Excess becomes overflow for LP incentives.
     * @param cap New cap in XOM (18 decimals). Cannot be zero.
     */
    function setGatewayRewardCap(
        uint256 cap
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cap == 0) revert ZeroCap();
        uint256 old = gatewayRewardCap;
        gatewayRewardCap = cap;
        emit RewardCapUpdated(0, old, cap);
    }

    /**
     * @notice Set the per-epoch reward cap for service/computation nodes
     * @dev V3: Non-gateway nodes (Bootstrap type 1, 2) are capped at
     *      this value per epoch. Excess becomes overflow.
     * @param cap New cap in XOM (18 decimals). Cannot be zero.
     */
    function setServiceNodeRewardCap(
        uint256 cap
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cap == 0) revert ZeroCap();
        uint256 old = serviceNodeRewardCap;
        serviceNodeRewardCap = cap;
        emit RewardCapUpdated(1, old, cap);
    }

    /**
     * @notice Set the LiquidityOverflowPool address
     * @dev V3: Only valid contract addresses accepted. V5 fix: this
     *      NatSpec claim is now actually enforced (`code.length`) —
     *      `_routeOverflow` calls `distributeOverflow` on whatever
     *      this is set to, so an EOA reference would silently eat the
     *      overflow's `forceApprove` with no distribution ever
     *      happening.
     * @param pool New overflow pool address
     */
    function setOverflowPool(
        address pool
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pool == address(0)) revert ZeroAddress();
        if (pool.code.length == 0) revert NotAContract(pool);
        address old = overflowPool;
        overflowPool = pool;
        emit OverflowPoolUpdated(old, pool);
    }

    /**
     * @notice Enable or disable overflow routing
     * @dev V3: Circuit breaker. Disable if LiquidityOverflowPool
     *      has issues; overflow accumulates in this contract.
     * @param enabled True to enable routing, false to disable
     */
    function setOverflowEnabled(
        bool enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        overflowEnabled = enabled;
        emit OverflowEnabledUpdated(enabled);
    }

    /**
     * @notice Set the cross-chain overflow batch trigger
     * @dev V3: dust guard — below this threshold, overflow accumulates.
     *      V6: the threshold at which the accumulated cross-chain bucket
     *      ({pendingCrossChainOverflow}) is sent as ONE ICTT message.
     *      Governs hop-1 message cadence only; the L1-pool leg is pushed
     *      every epoch regardless. At the live 0.01 XOM value every epoch
     *      crosses the trigger (per-epoch sends — the V4 behavior this
     *      variable historically produced).
     * @param amount Minimum accumulated bucket in XOM (18 decimals)
     */
    function setMinOverflowTransfer(
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amount == 0) revert ZeroAmount();
        uint256 old = minOverflowTransfer;
        minOverflowTransfer = amount;
        emit MinOverflowTransferUpdated(old, amount);
    }

    // ══════════════════════════════════════════════════════════════════
    //                  V4 ADMIN — CROSS-CHAIN OVERFLOW (2-hop)
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice V4: Set the L1 ICTT `ERC20TokenHome` for XOM.
     * @dev Pass `address(0)` to disable the cross-chain leg —
     *      `_routeOverflow` then sends 100% to the L1 local pool.
     *      V5 fix: a NON-zero value must have code — this is an L1
     *      address (unlike {setCchainSender}/{setCchainRemoteTransferrer}
     *      below, which name addresses on the destination C-Chain
     *      that this contract has no way to inspect from L1).
     * @param tokenHome The ICTT `ERC20TokenHome` (mainnet:
     *        `0xc0Fb51A663ADeD93983E107C962edAC040E27b2D`).
     */
    function setIcttTokenHome(
        address tokenHome
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tokenHome != address(0) && tokenHome.code.length == 0) {
            revert NotAContract(tokenHome);
        }
        address old = icttTokenHome;
        icttTokenHome = tokenHome;
        emit IcttTokenHomeUpdated(old, tokenHome);
    }

    /**
     * @notice V4: Set the C-Chain `OverflowOFTSender` recipient.
     * @dev Pass `address(0)` to disable the cross-chain leg.
     * @param sender Recipient address on Avalanche C-Chain.
     */
    function setCchainSender(
        address sender
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address old = cchainSender;
        cchainSender = sender;
        emit CchainSenderUpdated(old, sender);
    }

    /**
     * @notice V4: Set the C-Chain `ERC20TokenRemote` transferrer
     *         (BridgedXOM).
     * @param transferrer Address of the destination ICTT transferrer
     *        (mainnet: `0xAF72f6caF76775DaEAbAf5C82Ce05D97359C8Fa1`).
     */
    function setCchainRemoteTransferrer(
        address transferrer
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address old = cchainRemoteTransferrer;
        cchainRemoteTransferrer = transferrer;
        emit CchainRemoteTransferrerUpdated(old, transferrer);
    }

    /**
     * @notice V4: Set the Avalanche C-Chain blockchain ID.
     * @param id Teleporter blockchain ID (mainnet C-Chain:
     *        `0x0427d4b22a2a78bcddd456742caf91b56badbff985ee19aef14573e7343fd652`).
     */
    function setCchainBlockchainID(
        bytes32 id
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 old = cchainBlockchainID;
        cchainBlockchainID = id;
        emit CchainBlockchainIDUpdated(old, id);
    }

    /**
     * @notice V4: Set the fraction (basis points) of overflow routed
     *         cross-chain via ICTT.
     * @dev Default `DEFAULT_OVERFLOW_WEIGHTS_BPS` remote sum is 6500
     *      (ETH 1200 + ARB 2200 + BASE 2200 + POL 900). Set to 0 to
     *      disable; set to 10000 to send everything cross-chain.
     *      Per-chain split BELOW the C-Chain hop lives in the
     *      `OverflowOFTSender` on C-Chain — this contract only
     *      decides the L1-vs-cross-chain bucket split.
     * @param bps New remote-share basis points (0..BPS_DENOMINATOR).
     */
    function setRemoteShareBps(
        uint16 bps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > BPS_DENOMINATOR) revert RemoteShareBpsTooHigh();
        uint16 old = remoteShareBps;
        remoteShareBps = bps;
        emit RemoteShareBpsUpdated(old, bps);
    }

    // ══════════════════════════════════════════════════════════════════
    //                      EXTERNAL VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Check if the contract has been permanently ossified
     * @return True if ossified (no further upgrades possible)
     */
    function isOssified() external view returns (bool) {
        return _ossified;
    }

    /**
     * @notice Get validator's pending rewards
     * @param validator Validator address
     * @return Amount of unclaimed rewards
     */
    function getPendingRewards(
        address validator
    ) external view returns (uint256) {
        return accumulatedRewards[validator];
    }

    /**
     * @notice Get validator's total claimed rewards
     * @param validator Validator address
     * @return Total amount claimed
     */
    function getTotalClaimed(
        address validator
    ) external view returns (uint256) {
        return totalClaimed[validator];
    }

    /**
     * @notice Get validator's current weight
     * @param validator Validator address
     * @return Current weight for reward distribution
     */
    function getValidatorWeight(
        address validator
    ) external view returns (uint256) {
        return _calculateValidatorWeight(
            validator, getCurrentEpoch()
        );
    }

    /**
     * @notice Get epochs pending processing
     * @return Number of unprocessed epochs
     */
    function getPendingEpochs()
        external
        view
        returns (uint256)
    {
        uint256 currentEpoch = getCurrentEpoch();
        if (currentEpoch < lastProcessedEpoch + 1) {
            return 0;
        }
        return currentEpoch - lastProcessedEpoch;
    }

    /**
     * @notice Get contract's XOM balance
     * @return Balance available for rewards
     */
    function getRewardBalance()
        external
        view
        returns (uint256)
    {
        return xomToken.balanceOf(address(this));
    }

    /**
     * @notice Check if the contract is solvent
     * @dev M-02 Round 3 audit fix: compares actual token balance
     *      against total outstanding (unclaimed) rewards.
     * @return True if balance covers all outstanding obligations
     */
    function isSolvent() external view returns (bool) {
        // solhint-disable-next-line gas-strict-inequalities
        return xomToken.balanceOf(address(this))
            >= totalOutstandingRewards;
    }

    /**
     * @notice Get effective weight for a validator
     * @dev Returns the base weight scaled by both the penalty
     *      multiplier (rewardMultiplier) and the role bonus
     *      multiplier (roleMultiplier). Mirrors the logic in
     *      _computeEpochWeights() for external visibility.
     * @param validator Address of the validator
     * @return Effective weight after penalty and role application
     */
    function getEffectiveWeight(
        address validator
    ) external view returns (uint256) {
        uint256 weight = _calculateValidatorWeight(
            validator, getCurrentEpoch()
        );
        // Apply penalty multiplier (with expiry check)
        uint256 mult = rewardMultiplier[validator];
        if (mult != 0) {
            // M-02 R4: Check penalty expiry
            uint256 expiry = penaltyExpiresAt[validator];
            bool penaltyExpired = expiry != 0
                // solhint-disable-next-line not-rely-on-time
                && block.timestamp > expiry;
            if (!penaltyExpired) {
                weight = (weight * mult) / 100;
            }
        }
        // Apply role bonus (activity-gated; VT-18 attestation-aware)
        // V2: Auto-derive from Bootstrap if unset
        uint256 roleMul = roleMultiplier[validator];
        if (
            roleMul == 0
                && bootstrapContract != address(0)
        ) {
            roleMul = _bootstrapRoleMultiplier(validator);
        }
        if (
            roleMul > 10000
                && _attestationScore(
                    validator, getCurrentEpoch()
                ) > 0
        ) {
            weight = (weight * roleMul) / 10000;
        }
        return weight;
    }

    /**
     * @notice Get the reward multiplier for a validator
     * @dev Returns 0 if no explicit multiplier set (treated as 100%).
     * @param validator Address to check
     * @return Multiplier value (0=default/100%, 1-100=explicit)
     */
    function getRewardMultiplier(
        address validator
    ) external view returns (uint256) {
        return rewardMultiplier[validator];
    }

    /**
     * @notice Get the role multiplier for a validator
     * @dev V2: If no manual override is set, auto-derives from
     *      Bootstrap.sol nodeType. Gateway (type 0) = 15000 (1.5x),
     *      all others = 10000 (1.0x).
     * @param validator Address to check
     * @return Multiplier in basis points (10000 = 1.0x default)
     */
    function getRoleMultiplier(
        address validator
    ) external view returns (uint256) {
        uint256 m = roleMultiplier[validator];
        if (m != 0) return m;
        // V2: Auto-derive from Bootstrap
        if (bootstrapContract != address(0)) {
            return _bootstrapRoleMultiplier(validator);
        }
        return 10000;
    }

    /**
     * @notice Get the pending upgrade details
     * @return newImplementation Proposed address (zero if none)
     * @return effectiveTimestamp When upgrade can execute
     */
    function getPendingUpgrade()
        external
        view
        returns (
            address newImplementation,
            uint256 effectiveTimestamp
        )
    {
        newImplementation =
            pendingUpgrade.newImplementation;
        effectiveTimestamp =
            pendingUpgrade.effectiveTimestamp;
    }

    // ══════════════════════════════════════════════════════════════════
    //                       PUBLIC VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Check if validator is currently active
     * @param validator Address to check
     * @return True if heartbeat within timeout
     */
    function isValidatorActive(
        address validator
    ) public view returns (bool) {
        if (lastHeartbeat[validator] == 0) return false;
        // solhint-disable-next-line not-rely-on-time
        return (block.timestamp - lastHeartbeat[validator])
            < HEARTBEAT_TIMEOUT + 1;
    }

    /**
     * @notice Calculate current block reward based on next epoch
     * @return Block reward in XOM (18 decimals)
     * @dev Convenience wrapper using lastProcessedEpoch + 1
     */
    function calculateBlockReward()
        public
        view
        returns (uint256)
    {
        return calculateBlockRewardForEpoch(
            lastProcessedEpoch + 1
        );
    }

    /**
     * @notice Get current epoch number
     * @return Current epoch based on timestamp
     */
    function getCurrentEpoch()
        public
        view
        returns (uint256)
    {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < genesisTimestamp) {
            return 0;
        }
        // solhint-disable-next-line not-rely-on-time
        uint256 elapsed = block.timestamp - genesisTimestamp;
        return elapsed / EPOCH_DURATION;
    }

    /**
     * @notice Calculate block reward for a given epoch
     * @param epoch The epoch number to calculate reward for
     * @return Block reward in XOM (18 decimals)
     *
     * @dev Reward decreases by 1% every 6,311,520 epochs.
     *      Uses epoch number (time-based) rather than
     *      totalBlocksProduced to prevent emission schedule
     *      desynchronization when epochs are processed late
     *      (M-02 fix from Round 1).
     *
     *      Emission Schedule Examples:
     *        Epoch 0: 15.602 XOM (initial)
     *        Epoch 6,311,520: 15.446 XOM (1 reduction)
     *        Epoch 12,623,040: 15.291 XOM (2 reductions)
     *        Epoch ~315M (~year 20): ~9.46 XOM
     *        Epoch ~625M (~year 40): ~5.79 XOM
     *        Epoch 631,152,000+: 0 XOM (exhausted)
     */
    function calculateBlockRewardForEpoch(
        uint256 epoch
    ) public pure returns (uint256) {
        uint256 reductions =
            epoch / BLOCKS_PER_REDUCTION;

        if (reductions > MAX_REDUCTIONS - 1) {
            return 0; // Rewards exhausted
        }

        uint256 reward = INITIAL_BLOCK_REWARD;

        // Apply compound reduction
        for (uint256 i = 0; i < reductions;) {
            reward =
                (reward * REDUCTION_FACTOR)
                / REDUCTION_DENOMINATOR;
            unchecked { ++i; }
        }

        return reward;
    }

    /**
     * @notice Estimate overflow for the current epoch
     * @dev V3: Simulates reward distribution with caps to project
     *      how much overflow would be generated. Read-only estimation
     *      using current validator set and heartbeat state.
     * @return overflow Estimated XOM overflow for current epoch
     * @return validatorTotal Estimated total validator rewards
     */
    function estimateOverflow()
        external
        view
        returns (uint256 overflow, uint256 validatorTotal)
    {
        uint256 epoch = getCurrentEpoch();
        uint256 epochReward = calculateBlockRewardForEpoch(epoch);

        address[] memory validators =
            omniCore.getActiveNodes();

        (
            ,
            uint256[] memory weights,
            uint256 totalWeight
        ) = _computeEpochWeights(validators, epoch);

        if (totalWeight == 0) return (epochReward, 0);

        for (uint256 i = 0; i < validators.length;) {
            if (weights[i] > 0) {
                uint256 reward =
                    (epochReward * weights[i]) / totalWeight;

                if (gatewayRewardCap > 0) {
                    uint256 cap = _getRewardCapForValidator(
                        validators[i]
                    );
                    if (reward > cap) {
                        reward = cap;
                    }
                }

                validatorTotal += reward;
            }
            unchecked { ++i; }
        }

        if (epochReward > validatorTotal) {
            overflow = epochReward - validatorTotal;
        }
    }

    /**
     * @notice Get the reward cap for a specific validator address
     * @dev V3: Public wrapper around _getRewardCapForValidator.
     *      Returns 0 if caps are not configured (pre-V3 behavior).
     * @param validator Address to check
     * @return cap Per-epoch reward cap in XOM (18 decimals)
     */
    function getRewardCap(
        address validator
    ) external view returns (uint256 cap) {
        if (gatewayRewardCap == 0) return 0;
        return _getRewardCapForValidator(validator);
    }

    // ══════════════════════════════════════════════════════════════════
    //                      INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Authorize contract upgrade
     * @dev H-01 Round 3 audit fix: verifies that the upgrade
     *      was proposed via proposeUpgrade() and the 48h timelock
     *      has elapsed. Reverts if contract is ossified or if the
     *      implementation address does not match the proposal.
     *      MUST be combined with a multisig wallet for production.
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();

        PendingUpgrade memory pending = pendingUpgrade;

        // Verify proposal exists and matches
        if (
            pending.newImplementation != newImplementation
        ) {
            revert UpgradeNotProposed(
                pending.newImplementation,
                newImplementation
            );
        }

        // Verify timelock elapsed
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < pending.effectiveTimestamp) {
            revert TimelockNotElapsed();
        }

        // Clear pending upgrade
        delete pendingUpgrade;
    }

    /**
     * @notice Reset expired penalties for validators
     * @dev M-02 Round 4: Iterates validators and resets any
     *      penalty whose expiry has passed. Called during epoch
     *      processing to garbage-collect expired penalties.
     * @param validators Array of validator addresses to check
     */
    function _resetExpiredPenalties(
        address[] memory validators
    ) internal {
        uint256 len = validators.length;
        uint256 cap = len > MAX_VALIDATORS_PER_EPOCH
            ? MAX_VALIDATORS_PER_EPOCH
            : len;

        for (uint256 i = 0; i < cap;) {
            address v = validators[i];
            uint256 expiry = penaltyExpiresAt[v];
            if (
                expiry != 0
                    // solhint-disable-next-line not-rely-on-time
                    && block.timestamp > expiry
            ) {
                rewardMultiplier[v] = 0; // Reset to default
                delete penaltyExpiresAt[v];
                emit PenaltyExpired(v);
            }
            unchecked { ++i; }
        }
    }

    /**
     * @notice Distribute epoch rewards to validators
     * @dev Updates totalOutstandingRewards for solvency
     *      tracking (M-02 Round 3 fix). Emits per-validator
     *      RewardDistributed events.
     *
     *      H-01 Round 6: Added solvency guard to prevent
     *      over-allocation beyond TOTAL_VALIDATOR_POOL. Before
     *      distributing, verifies that sufficient pool balance
     *      remains. If the epoch reward would exceed available
     *      balance, it is proportionally reduced to what remains.
     *      Emits PoolRunningLow when pool drops below 10%.
     *      Emits EpochRewardCapped when reward is reduced.
     *
     * @param validators Array of validator addresses
     * @param weights Per-validator weight array
     * @param totalWeight Sum of all weights
     * @param epochReward Total reward for this epoch
     * @param epoch Epoch number (for event emission)
     */
    function _distributeRewards(
        address[] memory validators,
        uint256[] memory weights,
        uint256 totalWeight,
        uint256 epochReward,
        uint256 epoch
    ) internal {
        if (totalWeight == 0) return;

        // H-01 R6: Solvency guard — cap epoch reward to
        // remaining pool and available contract balance
        uint256 poolRemaining = 0;
        if (TOTAL_VALIDATOR_POOL > totalDistributed) {
            poolRemaining =
                TOTAL_VALIDATOR_POOL - totalDistributed;
        }

        uint256 contractBalance =
            xomToken.balanceOf(address(this));
        uint256 availableForRewards = contractBalance;
        if (availableForRewards > totalOutstandingRewards) {
            availableForRewards -= totalOutstandingRewards;
        } else {
            availableForRewards = 0;
        }
        // V6: exclude the cross-chain batch accumulator. XOM parked in
        // {pendingCrossChainOverflow} is committed to a future ICTT send;
        // while it sits in this contract's balance it must NOT be
        // re-distributable as validator rewards (the batch would then be
        // spent twice — once here, once on the ICTT send).
        if (availableForRewards > pendingCrossChainOverflow) {
            availableForRewards -= pendingCrossChainOverflow;
        } else {
            availableForRewards = 0;
        }

        // Use the lesser of pool remaining and available balance
        uint256 maxDistributable =
            poolRemaining < availableForRewards
                ? poolRemaining
                : availableForRewards;

        uint256 effectiveReward = epochReward;
        if (effectiveReward > maxDistributable) {
            effectiveReward = maxDistributable;
            emit EpochRewardCapped(
                epoch, epochReward, effectiveReward
            );
        }

        // Nothing to distribute if pool is exhausted
        if (effectiveReward == 0) return;

        uint256 epochDistributed = 0;

        for (uint256 i = 0; i < validators.length;) {
            if (weights[i] > 0) {
                uint256 validatorReward =
                    (effectiveReward * weights[i])
                    / totalWeight;

                // V3: Apply per-node-type cap if caps are set
                if (gatewayRewardCap > 0) {
                    uint256 cap = _getRewardCapForValidator(
                        validators[i]
                    );
                    if (validatorReward > cap) {
                        validatorReward = cap;
                    }
                }

                accumulatedRewards[validators[i]] +=
                    validatorReward;
                // M-02 R3: Track outstanding obligations
                totalOutstandingRewards += validatorReward;
                epochDistributed += validatorReward;

                emit RewardDistributed(
                    validators[i],
                    epoch,
                    validatorReward,
                    weights[i]
                );
            }
            unchecked { ++i; }
        }

        // H-01 R6: Update cumulative distribution tracker
        totalDistributed += epochDistributed;

        // V3: Route overflow to LiquidityOverflowPool
        // Overflow = what the epoch was worth minus what validators got
        if (effectiveReward > epochDistributed) {
            uint256 overflow =
                effectiveReward - epochDistributed;
            _routeOverflow(overflow, epoch);
        }

        // H-01 R6: Emit warning when pool drops below 10%
        uint256 newRemaining = 0;
        if (TOTAL_VALIDATOR_POOL > totalDistributed) {
            newRemaining =
                TOTAL_VALIDATOR_POOL - totalDistributed;
        }
        uint256 percentBps =
            (newRemaining * 10_000) / TOTAL_VALIDATOR_POOL;
        if (percentBps < POOL_LOW_THRESHOLD_BPS) {
            emit PoolRunningLow(
                newRemaining, totalDistributed, percentBps
            );
        }
    }

    /**
     * @notice Route overflow XOM to the L1 LiquidityOverflowPool and,
     *         if configured, bridge a fraction to the C-Chain
     *         `OverflowOFTSender` via ICTT for LayerZero-OFT dispatch
     *         to remote LP pools.
     * @dev V3 baseline: capped epoch rewards leave excess; that excess
     *      is split across active reward sinks.
     *      V4 extension (LP-5, 2-hop architecture):
     *        - The bucket `overflow * remoteShareBps / BPS_DENOMINATOR`
     *          is sent in a SINGLE ICTT call to `cchainSender` on
     *          Avalanche C-Chain (chain ID 43114). The C-Chain
     *          `OverflowOFTSender` then dispatches per-chain via
     *          LayerZero OFT.
     *        - The complement stays at the L1 `LiquidityOverflowPool`.
     *        - Skip-not-revert: when the cross-chain leg is not fully
     *          configured (any of `icttTokenHome` /
     *          `cchainSender` / `cchainRemoteTransferrer` /
     *          `cchainBlockchainID` unset) OR the ICTT send reverts,
     *          the bucket falls back to the L1 share.
     *
     *      V6 change (the overflow-flood fix — Option C, 2026-09):
     *        - The cross-chain bucket is no longer bridged per-epoch.
     *          It ACCUMULATES in {pendingCrossChainOverflow}, and ONE
     *          ICTT message is sent when the accumulator reaches
     *          {minOverflowTransfer}, which V6 re-purposes as the
     *          cross-chain batch trigger. The per-epoch message flood
     *          (~35K/day at 2s epochs on the shared user-bridge lane)
     *          drops to the batch cadence. At the legacy 0.01 XOM
     *          threshold the accumulator crosses every epoch, so V6 is
     *          byte-identical to V4 (one send per epoch, same amounts) —
     *          for every epoch whose cross-chain bucket itself clears the
     *          trigger, which at live magnitudes (bucket ≈ 10 XOM ≫ 0.01)
     *          is every epoch. In the sub-bucket tail V6 deliberately
     *          pushes the L1 local leg every epoch where V4 parked
     *          everything below its dust gate.
     *        - The L1-pool leg is pushed EVERY epoch, unchanged — it is
     *          same-chain, cheap, and its cadence is not the problem.
     *        - The old pre-split dust gate (`overflow <
     *          minOverflowTransfer => return`) is REMOVED. It would
     *          have let a raised threshold suppress BOTH legs and park
     *          the emission in this contract (no XOM sweep exists) —
     *          exactly the Option-A pathology this upgrade replaces.
     *        - Distribution accounting ({totalDistributed}) now bumps
     *          at COMMIT: the local leg when it lands at the L1 pool,
     *          the cross-chain leg when the ICTT send executes (inside
     *          {_trySendToCChain}). No amount is ever counted before it
     *          actually leaves this contract.
     *
     *      Trustless properties:
     *        - Cross-chain recipient is a CONTRACT address. An EOA
     *          never holds overflow XOM between L1 and the destination
     *          pool. The C-Chain `OverflowOFTSender` enforces the same
     *          guarantee for the OFT leg.
     *        - ICTT primary fee is 0 (validators self-relay via the
     *          existing Teleporter pipeline), so no fee budget is
     *          required and `processMultipleEpochs` (permissionless)
     *          does not need to attach value.
     *        - Local-share send wraps the existing V3 circuit-breaker
     *          try/catch so a downstream pool failure cannot brick the
     *          epoch.
     *        - Skip-not-revert (unchanged): an unconfigured leg or a
     *          failed ICTT send rolls the bucket (including any
     *          accumulated portion) into the L1 share — XOM keeps
     *          moving to LP stakers rather than parking in this
     *          contract. If the L1 pool push then fails in the same
     *          epoch, the rolled portion is re-credited to
     *          {pendingCrossChainOverflow} and retried later, so a
     *          double failure can never silently convert committed
     *          overflow into validator-distributable surplus.
     *
     * @param overflow Amount of excess XOM to route.
     * @param epoch Epoch that generated the overflow.
     */
    function _routeOverflow(
        uint256 overflow,
        uint256 epoch
    ) internal {
        if (!overflowEnabled) return;
        if (overflowPool == address(0)) return;

        // ---- 1) Split the epoch's overflow ----------------------------
        // bucket = overflow * remoteShareBps / 10000 (cross-chain leg).
        // localShare = overflow - bucket (L1 pool leg). Exact complement
        // (no dust): bucket + localShare == overflow.
        uint16 shareBps = remoteShareBps;
        uint256 bucket = (overflow * shareBps) / BPS_DENOMINATOR;
        uint256 localShare = overflow - bucket;

        // Amount rolled from the cross-chain accumulator (or its per-epoch
        // bucket) into the local share because the leg could not take it
        // THIS epoch. If the L1 pool push below then also fails, this
        // amount is re-credited to {pendingCrossChainOverflow} so it stays
        // committed to overflow routing and is retried on a later epoch —
        // it must never silently become validator-distributable surplus.
        uint256 rolledToLocal;

        // ---- 2) Cross-chain bucket: accumulate, then batch-send -------
        // V6: the bucket is only bridged once {pendingCrossChainOverflow}
        // reaches {minOverflowTransfer}. The L1 leg below stays per-epoch.
        bool cchainConfigured = icttTokenHome != address(0)
            && cchainSender != address(0)
            && cchainRemoteTransferrer != address(0)
            && cchainBlockchainID != bytes32(0);

        if (bucket > 0 && cchainConfigured) {
            uint256 pending = pendingCrossChainOverflow + bucket;
            if (pending >= minOverflowTransfer) {
                // Threshold crossed: ONE ICTT message for the whole
                // accumulated bucket. Reset the accumulator FIRST (CEI);
                // on a failed send the whole amount falls back to the L1
                // share below — never double-counted.
                pendingCrossChainOverflow = 0;
                bool ok = _trySendToCChain(pending, epoch);
                if (!ok) {
                    localShare += pending;
                    rolledToLocal = pending;
                }
            } else {
                // Below the batch trigger: hold for a later send.
                pendingCrossChainOverflow = pending;
            }
        } else {
            // The cross-chain leg is NOT operational this epoch: either the
            // path is unconfigured (disabled via `setIcttTokenHome(0)` &
            // co. — documented as "100% local") or `remoteShareBps == 0`
            // (no bucket is ever produced again, so nothing parked could
            // ever be sent). Roll the ENTIRE parked accumulator — not just
            // this epoch's bucket — into the L1 share and reset it. This
            // is the skip-not-revert guarantee applied to the accumulator:
            // overflow must never strand in this contract with no flush
            // path while the leg is down. (V6 audit fix: an earlier
            // revision rolled only the fresh bucket, stranding any
            // already-accumulated amount with no way out.)
            uint256 parked = pendingCrossChainOverflow;
            if (parked > 0 || bucket > 0) {
                pendingCrossChainOverflow = 0;
                uint256 drained = parked + bucket;
                // Monitoring parity: V4 reported "would-have-bridged"
                // amounts via this event from the helper's skip path.
                emit CrossChainOverflowSkipped(epoch, drained);
                localShare += drained;
                rolledToLocal = drained;
            }
        }

        // ---- 3) Push the local share to the L1 pool -------------------
        // V3/V4 path, unchanged cadence: every epoch, whether or not the
        // cross-chain bucket was sent this epoch.
        if (localShare == 0) {
            // 100% routed cross-chain; nothing left for L1 pool.
            return;
        }

        xomToken.forceApprove(overflowPool, localShare);
        try ILiquidityOverflowPool(overflowPool)
            .distributeOverflow(localShare)
        {
            // V6: bump at commit. {totalDistributed} tracks overflow that
            // actually left this contract; the local leg is committed
            // here, the cross-chain leg inside {_trySendToCChain}.
            totalDistributed += localShare;
            totalOverflowTransferred += localShare;
            // NOTE: Do NOT add to totalOutstandingRewards here.
            // Overflow XOM has left this contract (transferred to
            // LiquidityOverflowPool). It is no longer an obligation
            // of OmniValidatorRewards.

            emit OverflowRouted(
                epoch, localShare, totalOverflowTransferred
            );
        } catch (bytes memory reason) {
            // Revert approval on failure. No counter has been bumped for
            // the local share (it never left), so there is nothing to
            // undo here. If a cross-chain amount had been rolled into the
            // local share this epoch (failed batched send, or leg drain),
            // re-credit it to the accumulator for a later retry.
            xomToken.forceApprove(overflowPool, 0);
            if (rolledToLocal > 0) {
                pendingCrossChainOverflow += rolledToLocal;
            }

            emit OverflowRoutingFailed(
                epoch, localShare, reason
            );
        }
    }

    /**
     * @notice Try to bridge `bucket` XOM via ICTT to the C-Chain
     *         `OverflowOFTSender`. Returns false on any failure.
     * @dev CEI: approves the ICTT TokenHome, bumps
     *      `totalOverflowTransferred` BEFORE the external call. On
     *      revert (caught) it restores the counter + resets the
     *      approval. This protects against a malicious TokenHome
     *      attempting a callback during `send`.
     *
     *      The skip path activates when any required config is unset
     *      (`icttTokenHome`, `cchainSender`, `cchainRemoteTransferrer`,
     *      `cchainBlockchainID == 0`).
     *
     * @param bucket XOM amount to bridge.
     * @param epoch Originating epoch (for event emission).
     * @return ok True if the send was executed; false on skip/fail.
     */
    function _trySendToCChain(
        uint256 bucket,
        uint256 epoch
    ) internal returns (bool ok) {
        address tokenHome = icttTokenHome;
        address recipient = cchainSender;
        address transferrer = cchainRemoteTransferrer;
        bytes32 destBlockchainID = cchainBlockchainID;

        // Skip if any leg of the path is unconfigured.
        if (
            tokenHome == address(0)
                || recipient == address(0)
                || transferrer == address(0)
                || destBlockchainID == bytes32(0)
        ) {
            emit CrossChainOverflowSkipped(epoch, bucket);
            return false;
        }

        // Approve XOM for the ICTT TokenHome (lock pattern).
        xomToken.forceApprove(tokenHome, bucket);

        // CEI: bump cumulative BEFORE the external call. On revert
        // (caught below) we restore. This blocks adapter-side
        // reentrancy attempts from observing post-send state.
        // V6: {totalDistributed} is bumped HERE — the bucket is now
        // counted as distributed only when it is committed to the ICTT
        // send (the cross-chain counterpart of the local leg's
        // commit-time bump in {_routeOverflow}). While the bucket sits
        // in {pendingCrossChainOverflow} it is excluded from
        // `availableForRewards` instead.
        totalOverflowTransferred += bucket;
        totalDistributed += bucket;

        SendTokensInput memory input = SendTokensInput({
            destinationBlockchainID: destBlockchainID,
            destinationTokenTransferrerAddress: transferrer,
            recipient: recipient,
            primaryFeeTokenAddress: address(0),
            primaryFee: 0,
            secondaryFee: 0,
            requiredGasLimit: ICTT_DEFAULT_GAS_LIMIT,
            multiHopFallback: address(0)
        });

        try IICTTSender(tokenHome).send(input, bucket) {
            emit CrossChainOverflowSent(epoch, bucket);
            return true;
        } catch (bytes memory reason) {
            // Roll back CEI bumps + approval; bubble nothing — skip.
            // The "state change after external call" warning here is
            // intentional: this is rollback restoring pre-call state,
            // not a vulnerable post-call mutation. The catch arm runs
            // ONLY when the ICTT send reverted, so no value left the
            // contract; restoring the counters keeps invariants intact.
            // solhint-disable-next-line reentrancy
            totalOverflowTransferred -= bucket;
            // solhint-disable-next-line reentrancy
            totalDistributed -= bucket;
            xomToken.forceApprove(tokenHome, 0);
            emit OverflowRoutingFailed(epoch, bucket, reason);
            return false;
        }
    }

    /**
     * @notice Get the reward cap for a specific validator
     * @dev V3: Queries Bootstrap.sol for nodeType. Gateway nodes
     *      (type 0) use gatewayRewardCap. All others use
     *      serviceNodeRewardCap. Falls back to serviceNodeRewardCap
     *      if Bootstrap query fails (graceful degradation).
     * @param validator Validator address
     * @return cap The per-epoch reward cap in XOM (18 decimals)
     */
    function _getRewardCapForValidator(
        address validator
    ) internal view returns (uint256 cap) {
        if (bootstrapContract == address(0)) {
            return serviceNodeRewardCap;
        }

        try IBootstrapRewards(bootstrapContract).isNodeActive(
            validator
        ) returns (bool isActive, uint8 nodeType) {
            if (isActive && nodeType == 0) {
                return gatewayRewardCap;
            }
        } catch {
            // Bootstrap query failed — use service node cap
        }

        return serviceNodeRewardCap;
    }

    /**
     * @notice Compute active validator weights for an epoch
     * @dev Iterates at most MAX_VALIDATORS_PER_EPOCH
     *      validators to prevent gas DoS (H-03 fix).
     *      External calls to OmniParticipation and OmniCore
     *      are wrapped in try/catch per validator, so one
     *      failing validator does not block the entire epoch
     *      (M-01 Round 3 fix).
     *      V2 H-02 fix: Validators below minStakeForRewards
     *      are skipped entirely, preventing Sybil dilution.
     * @param validators Array of validator addresses
     * @param epoch Epoch to compute weights for
     * @return activeCount Number of active validators
     * @return weights Per-validator weight array
     * @return totalWeight Sum of all weights
     */
    function _computeEpochWeights(
        address[] memory validators,
        uint256 epoch
    )
        internal
        view
        returns (
            uint256 activeCount,
            uint256[] memory weights,
            uint256 totalWeight
        )
    {
        uint256 count = validators.length;
        uint256 cap = count > MAX_VALIDATORS_PER_EPOCH
            ? MAX_VALIDATORS_PER_EPOCH
            : count;

        weights = new uint256[](count);
        uint256 minStake = minStakeForRewards;

        // M-02 R6: Calculate the maximum epoch for which a heartbeat
        // is considered valid. A validator with lastHeartbeatEpoch = E
        // is considered active for epochs up to E + heartbeatEpochWindow.
        uint256 heartbeatEpochWindow =
            HEARTBEAT_TIMEOUT / EPOCH_DURATION;

        for (uint256 i = 0; i < cap;) {
            // VT-18: when the activity ledger is wired, eligibility derives
            // from committee-attested epochs (on-chain events only). Otherwise
            // fall back to the legacy epoch-based heartbeat check (M-02 R6),
            // with a timestamp fallback for pre-V3 heartbeats.
            bool epochActive;
            if (activityLedger != address(0)) {
                epochActive =
                    _attestationScore(validators[i], epoch) > 0;
            } else {
                uint256 hbEpoch = lastHeartbeatEpoch[validators[i]];
                epochActive = hbEpoch > 0
                    && epoch <= hbEpoch + heartbeatEpochWindow;

                // Fall back to timestamp-based check for validators who
                // submitted heartbeats before the V3 upgrade recorded epochs
                if (!epochActive) {
                    epochActive = isValidatorActive(validators[i]);
                    // Only allow timestamp fallback if this is a recent
                    // epoch (within heartbeat timeout of current epoch)
                    if (epochActive) {
                        uint256 currentEp = getCurrentEpoch();
                        if (
                            currentEp > epoch + heartbeatEpochWindow
                        ) {
                            epochActive = false;
                        }
                    }
                }
            }

            if (epochActive) {
                // V2 H-02: Skip validators below minimum stake
                // (exempt seed validators bypass this check)
                if (minStake > 0 && !stakeExempt[validators[i]]) {
                    try omniCore.getStake(validators[i])
                        returns (IOmniCore.Stake memory s)
                    {
                        if (
                            !s.active
                                || s.amount < minStake
                        ) {
                            unchecked { ++i; }
                            continue;
                        }
                    } catch {
                        // Stake check failed — skip validator
                        unchecked { ++i; }
                        continue;
                    }
                }
                uint256 baseWeight =
                    _calculateValidatorWeight(
                        validators[i], epoch
                    );
                // Apply reward multiplier (penalty)
                uint256 mult =
                    rewardMultiplier[validators[i]];
                if (mult != 0) {
                    // M-02 R4: Check penalty expiry
                    uint256 expiry =
                        penaltyExpiresAt[validators[i]];
                    if (
                        expiry != 0
                            // solhint-disable-next-line not-rely-on-time
                            && block.timestamp > expiry
                    ) {
                        // Penalty expired: treat as default
                        // (actual state reset in processEpoch
                        // via _resetExpiredPenalties)
                        // mult stays 0 logic = 100%
                    } else {
                        // Explicit multiplier set (1-100%)
                        baseWeight =
                            (baseWeight * mult) / 100;
                    }
                }
                // else mult == 0 → default = 100%

                // Apply role multiplier (gateway bonus)
                // Only applies when the validator is active (attested).
                // V2: Auto-derive from Bootstrap if unset.
                uint256 roleMul =
                    roleMultiplier[validators[i]];

                // If no manual override, check Bootstrap
                if (
                    roleMul == 0
                        && bootstrapContract != address(0)
                ) {
                    roleMul = _bootstrapRoleMultiplier(
                        validators[i]
                    );
                }

                if (
                    roleMul > 10000
                        && _attestationScore(
                            validators[i], epoch
                        ) > 0
                ) {
                    baseWeight =
                        (baseWeight * roleMul) / 10000;
                }
                // else no role bonus (unset or 1.0x)
                weights[i] = baseWeight;
                totalWeight += weights[i];
                ++activeCount;
            }
            unchecked { ++i; }
        }
    }

    /**
     * @notice Calculate validator weight for distribution
     * @dev Weight formula:
     *      40% participation score (OmniParticipation)
     *      30% staking amount (OmniCore)
     *      30% activity (60% heartbeat + 40% tx processing)
     *
     *      M-01 Round 3 fix: external calls wrapped in
     *      try/catch. If OmniParticipation or OmniCore
     *      revert, the affected component defaults to 0
     *      rather than blocking the entire epoch.
     * @param validator Validator address
     * @param epoch Epoch being calculated
     * @return Total weight (0-100 scale)
     */
    function _calculateValidatorWeight(
        address validator,
        uint256 epoch
    ) internal view returns (uint256) {
        // 1. Participation score (40% weight, 0-100 points)
        // M-01 R3: try/catch for external call resilience
        uint256 pScore;
        try participation.getTotalScore(validator)
            returns (uint256 s)
        {
            pScore = s;
        } catch {
            pScore = 0; // Fail-safe: no participation bonus
        }
        uint256 pComponent =
            (pScore * PARTICIPATION_WEIGHT) / 100;

        // 2. Staking score (30% weight)
        uint256 sComponent =
            _calculateStakingComponent(validator, epoch);

        // 3. Activity score (30% weight)
        uint256 aComponent =
            _calculateActivityComponent(validator, epoch);

        return pComponent + sComponent + aComponent;
    }

    /**
     * @notice Calculate staking component of weight
     * @dev Returns 0 if stake lock has expired to prevent
     *      flash-stake weight inflation (H-01 Round 1 fix).
     *      External call to omniCore.getStake() is wrapped in
     *      try/catch (M-01 Round 3 fix).
     * @param validator Validator address
     * @return Staking component (0-30 points)
     */
    function _calculateStakingComponent(
        address validator,
        uint256 epoch
    ) internal view returns (uint256) {
        // M-01 R3: try/catch for external call resilience
        IOmniCore.Stake memory stake;
        try omniCore.getStake(validator) returns (
            IOmniCore.Stake memory s
        ) {
            stake = s;
        } catch {
            return 0; // Fail-safe: no staking bonus
        }

        if (!stake.active || stake.amount == 0) {
            return 0;
        }

        // Use epoch-based time for lock expiry check so historical
        // batch processing correctly evaluates whether the lock was
        // active at the epoch being processed, not at block.timestamp.
        uint256 epochTimestamp = genesisTimestamp + epoch * EPOCH_DURATION;
        if (stake.lockTime < epochTimestamp + 1) {
            return 0;
        }

        // Normalize staking amount to 0-100 scale
        // Logarithmic scale for fairness
        uint256 stakingScore = _stakingTierScore(
            stake.amount
        );

        return (stakingScore * STAKING_WEIGHT) / 100;
    }

    /**
     * @notice Calculate activity component of weight
     * @dev Activity = 60% heartbeat + 40% tx processing.
     *      Heartbeat uses graduated scoring based on
     *      recency of last heartbeat rather than binary
     *      active/inactive (M-05 Round 1 fix). A validator
     *      who sent a heartbeat 1s ago scores higher than
     *      one whose heartbeat is 18s old.
     *      I-03 Round 4: Accumulates full numerator before
     *      dividing to minimize rounding precision loss.
     *      Old: (hScore*60/100 + txScore*40/100) * 30/100
     *      New: (hScore*60*30 + txScore*40*30) / 10000
     * @param validator Validator address
     * @param epoch Epoch being calculated
     * @return Activity component (0-30 points)
     */
    function _calculateActivityComponent(
        address validator,
        uint256 epoch
    ) internal view returns (uint256) {
        // VT-18: activity score from the on-chain committee-attestation
        // ledger (with legacy heartbeat fallback while the ledger is unset).
        uint256 hScore = _attestationScore(validator, epoch);

        // Transaction processing component (40%)
        uint256 txScore = _txProcessingScore(
            validator, epoch
        );

        // I-03 Round 4: Single division to preserve precision
        // numerator = hScore * HEARTBEAT_SUBWEIGHT
        //             * ACTIVITY_WEIGHT
        //           + txScore * TX_PROCESSING_SUBWEIGHT
        //             * ACTIVITY_WEIGHT
        // denominator = 100 * 100 = 10000
        uint256 numerator =
            (hScore * HEARTBEAT_SUBWEIGHT * ACTIVITY_WEIGHT)
            + (txScore * TX_PROCESSING_SUBWEIGHT
                * ACTIVITY_WEIGHT);

        return numerator / 10000;
    }

    /**
     * @notice Derive role multiplier from Bootstrap.sol nodeType
     * @dev V2: Queries Bootstrap.isNodeActive() for the validator.
     *      If the node is an active gateway (type 0), returns
     *      15000 bps (1.5x). Otherwise returns 10000 bps (1.0x).
     *      Wrapped in try/catch so Bootstrap failures default
     *      to 1.0x rather than blocking epoch processing.
     * @param validator Address to check
     * @return roleMul Multiplier in basis points
     */
    function _bootstrapRoleMultiplier(
        address validator
    ) internal view returns (uint256 roleMul) {
        try IBootstrapRewards(bootstrapContract).isNodeActive(
            validator
        ) returns (bool isActive, uint8 nodeType) {
            // Gateway (type 0) with active heartbeat => 1.5x
            // H-01: Cross-check OmniCore stake to prevent Sybil
            // dilution via permissionless Bootstrap registration.
            // Nodes without economic stake get base multiplier.
            if (isActive && nodeType == 0) {
                try omniCore.getStake(validator)
                    returns (IOmniCore.Stake memory s)
                {
                    if (s.active && s.amount > 0) {
                        return 15000;
                    }
                } catch {
                    // Stake check failed — default to 1.0x
                }
            }
        } catch {
            // Bootstrap call failed — default to 1.0x
        }
        return 10000;
    }

    /**
     * @notice Calculate the activity (heartbeat/attestation) score (VT-18)
     * @dev When {activityLedger} is set, the score is derived from the on-chain
     *      committee-attestation ledger: a validator attested active at epoch E
     *      scores 100 for epochs up to E + `HEARTBEAT_TIMEOUT / EPOCH_DURATION`.
     *      When the ledger is unset, this falls back to the legacy
     *      {_heartbeatScore} (timestamp-based binary heartbeat).
     * @param validator Validator address
     * @param epoch Epoch being calculated
     * @return score Binary score: 100 if active/attested, 0 if not
     */
    function _attestationScore(
        address validator,
        uint256 epoch
    ) internal view returns (uint256 score) {
        address ledger = activityLedger;
        if (ledger == address(0)) {
            // Legacy heartbeat fallback while the ledger is not wired.
            return _heartbeatScore(validator);
        }

        uint256 lastAtt;
        try IActivityLedger(ledger).lastAttestationEpoch(validator)
            returns (uint256 last)
        {
            lastAtt = last;
        } catch {
            // M-01 R3 parity: a misconfigured/reverting ledger fails closed
            // (0 activity) rather than bricking epoch processing.
            return 0;
        }
        if (lastAtt == 0) return 0;

        uint256 window = HEARTBEAT_TIMEOUT / EPOCH_DURATION;
        if (epoch <= lastAtt + window) {
            score = 100;
        }
        // else score = 0 (no recent attestation)
    }

    /**
     * @notice Calculate binary heartbeat score
     * @dev V2 M-01 fix: Simplified to binary 0/100.
     *      Heartbeat within HEARTBEAT_TIMEOUT = 100,
     *      otherwise = 0. Eliminates timing advantage
     *      from graduated scoring — either the validator
     *      is active or it is not. With 2-second epochs,
     *      sub-second gradations were meaningless and
     *      created a gameable attack surface.
     * @param validator Validator address
     * @return score Binary score: 100 if active, 0 if not
     */
    function _heartbeatScore(
        address validator
    ) internal view returns (uint256 score) {
        uint256 lastHb = lastHeartbeat[validator];
        if (lastHb == 0) return 0;

        // solhint-disable-next-line not-rely-on-time
        uint256 elapsed = block.timestamp - lastHb;

        if (elapsed < HEARTBEAT_TIMEOUT + 1) {
            score = 100;
        }
        // else score = 0 (expired / no heartbeat)
    }

    /**
     * @notice Calculate transaction processing score
     * @param validator Validator address
     * @param epoch Epoch to check
     * @return score Normalized score (0-100)
     */
    function _txProcessingScore(
        address validator,
        uint256 epoch
    ) internal view returns (uint256 score) {
        uint256 totalTx = epochTotalTransactions[epoch];
        if (totalTx > 0) {
            uint256 valTx =
                transactionsProcessed[validator][epoch];
            score = (valTx * 100) / totalTx;
            // Cap at 100%
            if (score > 100) score = 100;
        }
    }

    /**
     * @notice Map staking amount to a 0-100 score
     * @dev Uses linear interpolation within tiers to prevent
     *      cliff effects at boundaries (M-04 Round 1 fix):
     *      - 0 to 1M XOM: linear 0-20
     *      - 1M to 10M XOM: linear 20-40
     *      - 10M to 100M XOM: linear 40-60
     *      - 100M to 1B XOM: linear 60-80
     *      - 1B to 10B XOM: linear 80-100
     *      - 10B+ XOM: 100 (cap)
     * @param amount Staked XOM amount (18 decimals)
     * @return score Normalized score (0-100)
     */
    function _stakingTierScore(
        uint256 amount
    ) internal pure returns (uint256 score) {
        if (amount > 10_000_000_000 ether - 1) {
            score = 100;
        } else if (amount > 1_000_000_000 ether - 1) {
            // Linear interpolation: 80-100 over 1B-10B
            uint256 excess =
                amount - 1_000_000_000 ether;
            uint256 range = 9_000_000_000 ether;
            score = 80 + (excess * 20) / range;
        } else if (amount > 100_000_000 ether - 1) {
            // Linear interpolation: 60-80 over 100M-1B
            uint256 excess =
                amount - 100_000_000 ether;
            uint256 range = 900_000_000 ether;
            score = 60 + (excess * 20) / range;
        } else if (amount > 10_000_000 ether - 1) {
            // Linear interpolation: 40-60 over 10M-100M
            uint256 excess =
                amount - 10_000_000 ether;
            uint256 range = 90_000_000 ether;
            score = 40 + (excess * 20) / range;
        } else if (amount > 1_000_000 ether - 1) {
            // Linear interpolation: 20-40 over 1M-10M
            uint256 excess =
                amount - 1_000_000 ether;
            uint256 range = 9_000_000 ether;
            score = 20 + (excess * 20) / range;
        } else {
            // Linear scale for amounts below 1M: 0-20
            score = (amount * 20) / 1_000_000 ether;
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //              ERC2771Context Overrides (resolve diamond)
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Resolve _msgSender between ContextUpgradeable and
     *         ERC2771ContextUpgradeable
     * @dev Returns the original user address when called through
     *      the trusted forwarder. Used by claimRewards() to
     *      identify the actual validator.
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
