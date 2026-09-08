// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

// ════════════════════════════════════════════════════════════════════════
//                          OmniTreasuryV2
// ════════════════════════════════════════════════════════════════════════

/**
 * @title OmniTreasuryV2
 * @author OmniCoin Development Team
 * @notice Protocol-Owned Liquidity (POL) wallet that receives the 10%
 *         protocol share from every fee-distributing contract in the
 *         OmniBazaar ecosystem.
 * @dev Immutable (non-upgradeable) treasury controlled via AccessControl
 *      roles. Redeploy target that supersedes the original `OmniTreasury`
 *      (mainnet `0x18678DB9EeE901839744883B4780D918f086e6D0`). Because the
 *      v1 contract is immutable, this v2 is a fresh deployment, not an
 *      in-place upgrade.
 *
 *      v2 is a strict superset of v1. It keeps every v1 role, function,
 *      event, error, and the ERC-721/1155 holder behavior, and adds:
 *
 *      1. `POL_DEPLOYER_ROLE` — a least-privilege role that lets the
 *         `POLManager` automation contract move treasury balances into
 *         a whitelisted set of POL pool targets WITHOUT being granted the
 *         broad `GOVERNANCE_ROLE` (which also carries arbitrary `execute`
 *         and `executeBatch` powers). See {transferTokenToPOL} and
 *         {approveTokenForPOL}.
 *
 *      2. `polTargets` — an admin-managed allowlist of POL pool addresses
 *         the `POL_DEPLOYER_ROLE` is permitted to fund.
 *
 *      v2 also fixes two findings open against v1 in the Round 7 audit
 *      (2026-03-13):
 *
 *      - M-03 (malicious-token DoS on `transitionGovernance()`): the
 *        approval-revocation loop now wraps each `forceApprove(0)` in a
 *        try/catch so a single token whose `approve()` reverts on a zero
 *        amount can no longer brick the governance transition or
 *        `revokeAllApprovals()`. See {_revokeAllApprovalsInternal}.
 *
 *      - L-01 (self-transition bricks the contract): `transitionGovernance`
 *        now rejects any `newGovernance` / `newGuardian` / `newAdmin`
 *        equal to `msg.sender` (in addition to the existing
 *        `address(this)` guard). See {transitionGovernance}.
 *
 *      Accepts native XOM, ERC-20, ERC-721, and ERC-1155 tokens.
 *      All outbound transfers require GOVERNANCE_ROLE (or, for the two
 *      POL-scoped functions, POL_DEPLOYER_ROLE) and are blocked while the
 *      contract is paused.
 *
 *      SECURITY — ROLE ASSIGNMENT POLICY (audit-enforced):
 *      `POL_DEPLOYER_ROLE` MUST only ever be granted to the deployed
 *      `POLManager` contract. It MUST NEVER be granted to an externally
 *      owned account (EOA). The role is admined by `DEFAULT_ADMIN_ROLE`,
 *      so granting it goes through the same timelock as every other role
 *      change post-Pioneer-Phase. An EOA holding this role could drain the
 *      treasury into a whitelisted pool and then extract the LP position;
 *      the contract-only invariant is the security boundary that keeps the
 *      least-privilege design meaningful.
 */
contract OmniTreasuryV2 is
    AccessControl,
    ReentrancyGuard,
    Pausable,
    ERC721Holder,
    ERC1155Holder
{
    using SafeERC20 for IERC20;

    // ─────────────────────── Structs ───────────────────────────

    /**
     * @notice Tracks an active ERC-20 approval granted by this
     *         treasury (M-01 Round 6)
     * @param token The ERC-20 token address
     * @param spender The approved spender address
     */
    struct Approval {
        address token;
        address spender;
    }

    // ─────────────────────────── Constants ───────────────────────────

    /// @notice Role that can transfer assets, approve spenders, and
    ///         execute arbitrary calls through the treasury.
    bytes32 public constant GOVERNANCE_ROLE =
        keccak256("GOVERNANCE_ROLE");

    /// @notice Role that can pause and unpause the contract in an
    ///         emergency.
    bytes32 public constant GUARDIAN_ROLE =
        keccak256("GUARDIAN_ROLE");

    /// @notice Least-privilege role for the `POLManager` automation
    ///         contract.
    /// @dev Holders may call {transferTokenToPOL} and
    ///      {approveTokenForPOL} ONLY against addresses in the
    ///      `polTargets` allowlist. Holders CANNOT call `transferToken`
    ///      to arbitrary addresses, `execute`, `executeBatch`,
    ///      `transferNative`, `transferNFT`, or `transferERC1155`.
    ///      Admined by `DEFAULT_ADMIN_ROLE`. MUST only be granted to the
    ///      deployed `POLManager` contract — never to an EOA. See the
    ///      contract-level NatSpec ROLE ASSIGNMENT POLICY section.
    bytes32 public constant POL_DEPLOYER_ROLE =
        keccak256("POL_DEPLOYER_ROLE");

    /// @notice Maximum number of calls allowed in a single
    ///         `executeBatch` invocation.
    uint256 public constant MAX_BATCH_SIZE = 64;

    /// @notice Maximum number of bytes of return data retained from a
    ///         low-level call. Prevents a malicious target from forcing
    ///         unbounded memory expansion (VP-33 / S-04).
    uint256 public constant MAX_RETURN_DATA_LENGTH = 1024;

    /// @notice Maximum number of tracked active ERC-20 approvals.
    /// @dev Audit M-08: bounds the `_activeApprovals` array so the
    ///      `_revokeAllApprovalsInternal` loop — reached by both
    ///      {revokeAllApprovals} and {transitionGovernance} — can never
    ///      grow large enough to exceed the block gas limit and brick
    ///      the governance handoff. When the array is full,
    ///      {approveToken} / {approveTokenForPOL} revert
    ///      {TooManyActiveApprovals}; the relief valve is
    ///      {revokeAllApprovals}, which clears the array in one call.
    ///      The cap is generous: a treasury legitimately tracks only a
    ///      handful of live spenders, and 256 entries revoke well
    ///      within a block.
    uint256 public constant MAX_ACTIVE_APPROVALS = 256;

    // ─────────────────────── State Variables ──────────────────────

    /// @notice Whitelist of POL pool targets the `POL_DEPLOYER_ROLE`
    ///         may fund via {transferTokenToPOL} / {approveTokenForPOL}.
    /// @dev Managed exclusively by `DEFAULT_ADMIN_ROLE` via
    ///      {setPOLTarget}. Deliberately NOT writable by
    ///      `GOVERNANCE_ROLE` — if governance could edit this list, the
    ///      broad-privilege escape hatch the POL role exists to close
    ///      would be re-created. `address(this)` can never be a valid
    ///      target ({setPOLTarget} rejects it).
    mapping(address => bool) public polTargets;

    /// @notice Tracks the number of addresses holding
    ///         DEFAULT_ADMIN_ROLE to prevent accidental lockout.
    uint256 private _adminCount;

    /// @notice List of active ERC-20 approvals for revocation
    ///         tracking (M-01 Round 6)
    /// @dev Entries are appended in approveToken() / approveTokenForPOL()
    ///      and batch-revoked in revokeAllApprovals(). Duplicates are
    ///      harmless (forceApprove(0) is idempotent).
    Approval[] private _activeApprovals;

    // ──────────────────────────── Events ─────────────────────────────

    /// @notice Emitted when native XOM is received via `receive()`.
    /// @param sender The address that sent XOM.
    /// @param amount The amount of XOM received (in wei).
    event NativeReceived(address indexed sender, uint256 indexed amount);

    /// @notice Emitted when an ERC-20 token is transferred out.
    /// @param token  The ERC-20 token address.
    /// @param to     The recipient address.
    /// @param amount The amount transferred.
    event TokenTransferred(
        address indexed token,
        address indexed to,
        uint256 indexed amount
    );

    /// @notice Emitted when native XOM is transferred out.
    /// @param to     The recipient address.
    /// @param amount The amount of XOM sent (in wei).
    event NativeTransferred(address indexed to, uint256 indexed amount);

    /// @notice Emitted when an ERC-20 spending allowance is set.
    /// @param token   The ERC-20 token address.
    /// @param spender The approved spender address.
    /// @param amount  The approved amount.
    event TokenApproved(
        address indexed token,
        address indexed spender,
        uint256 indexed amount
    );

    /// @notice Emitted when an ERC-721 NFT is transferred out.
    /// @param nft     The ERC-721 contract address.
    /// @param to      The recipient address.
    /// @param tokenId The NFT token ID.
    event NFTTransferred(
        address indexed nft,
        address indexed to,
        uint256 indexed tokenId
    );

    /// @notice Emitted when ERC-1155 tokens are transferred out.
    /// @param token  The ERC-1155 contract address.
    /// @param to     The recipient address.
    /// @param id     The token type ID.
    /// @param amount The amount transferred.
    event ERC1155Transferred(
        address indexed token,
        address indexed to,
        uint256 indexed id,
        uint256 amount
    );

    /// @notice Emitted when a low-level call is executed.
    /// @param target The address called.
    /// @param value  The native XOM value sent.
    /// @param data   The calldata forwarded.
    event Executed(
        address indexed target,
        uint256 indexed value,
        bytes data
    );

    /// @notice Emitted after a batch of calls is executed.
    /// @param count The number of calls in the batch.
    event BatchExecuted(uint256 indexed count);

    /// @notice Emitted when governance is atomically transitioned
    ///         from the Pioneer Phase deployer to production contracts.
    /// @param newGovernance The new GOVERNANCE_ROLE holder (timelock).
    /// @param newGuardian   The new GUARDIAN_ROLE holder (multi-sig).
    /// @param newAdmin      The new DEFAULT_ADMIN_ROLE holder (timelock).
    event GovernanceTransitioned(
        address indexed newGovernance,
        address indexed newGuardian,
        address indexed newAdmin
    );

    /// @notice Emitted when all active approvals are revoked
    ///         (M-01 Round 6).
    /// @param count Number of approvals revoked.
    event AllApprovalsRevoked(uint256 indexed count);

    /// @notice Emitted when a single tracked approval cannot be revoked
    ///         because the token's `approve(spender, 0)` call reverted.
    /// @dev M-03 Round 7 fix: revocation is best-effort. The stuck token
    ///      and spender are surfaced so off-chain monitoring can flag
    ///      the residual allowance for manual attention.
    /// @param token   The ERC-20 token whose zero-approve reverted.
    /// @param spender The spender whose allowance could not be cleared.
    event ApprovalRevocationFailed(
        address indexed token,
        address indexed spender
    );

    /// @notice Emitted when a POL pool target is added to or removed
    ///         from the `polTargets` allowlist.
    /// @param target  The POL pool address.
    /// @param allowed True if the target is now whitelisted, false if
    ///                it was removed.
    event POLTargetSet(address indexed target, bool indexed allowed);

    /// @notice Emitted when the `POL_DEPLOYER_ROLE` moves ERC-20 tokens
    ///         into a whitelisted POL target.
    /// @param token  The ERC-20 token transferred.
    /// @param target The whitelisted POL pool that received the tokens.
    /// @param amount The amount transferred.
    event POLTokenTransferred(
        address indexed token,
        address indexed target,
        uint256 indexed amount
    );

    /// @notice Emitted when the `POL_DEPLOYER_ROLE` approves a
    ///         whitelisted POL target to spend an ERC-20 token.
    /// @param token  The ERC-20 token approved.
    /// @param target The whitelisted POL pool granted the allowance.
    /// @param amount The allowance amount.
    event POLTokenApproved(
        address indexed token,
        address indexed target,
        uint256 indexed amount
    );

    // ──────────────────────────── Errors ─────────────────────────────

    /// @notice Thrown when an address parameter is the zero address.
    error ZeroAddress();

    /// @notice Thrown when a transfer amount is zero.
    error ZeroAmount();

    /// @notice Thrown when a native XOM transfer fails.
    error NativeTransferFailed();

    /// @notice Thrown when a call in `execute` or `executeBatch` fails.
    /// @param index      The index of the failed call (0 for single).
    /// @param returnData The revert data returned by the failed call.
    error ExecutionFailed(uint256 index, bytes returnData);

    /// @notice Thrown when array lengths do not match in batch calls.
    error ArrayLengthMismatch();

    /// @notice Thrown when `execute` targets `address(this)`.
    error SelfCallNotAllowed();

    /// @notice Thrown when `executeBatch` exceeds the maximum batch size.
    error BatchTooLarge();

    /// @notice Thrown when the last DEFAULT_ADMIN_ROLE holder tries to
    ///         renounce or be revoked while the contract is paused.
    error CannotRemoveLastAdminWhilePaused();

    /// @notice Thrown when transitionGovernance targets the
    ///         treasury contract itself.
    error InvalidGovernanceTarget();

    /// @notice Thrown when revoking the last admin would leave
    ///         the treasury permanently without an administrator.
    error CannotRemoveLastAdmin();

    /// @notice Thrown when `transitionGovernance` would hand a role back
    ///         to `msg.sender`, which permanently bricks the contract
    ///         (L-01 Round 7).
    error CannotTransitionToSelf();

    /// @notice Thrown when `transitionGovernance` is given the same
    ///         address for two or more distinct roles.
    /// @dev Audit L-01 (this round): the governance, guardian, and admin
    ///      roles MUST go to three separate addresses. Collapsing them
    ///      into one address defeats the pause/unpause separation of
    ///      powers (a single key could pause then refuse to unpause, or
    ///      hold both arbitrary-call and emergency-halt authority).
    error DuplicateGovernanceTarget();

    /// @notice Thrown when a POL-scoped function targets an address that
    ///         is not in the `polTargets` allowlist.
    /// @param target The rejected, non-whitelisted target address.
    error POLTargetNotAllowed(address target);

    /// @notice Thrown when `POL_DEPLOYER_ROLE` is granted to an account
    ///         with no deployed bytecode (an EOA).
    /// @dev Audit M-03: the contract-only invariant for
    ///      `POL_DEPLOYER_ROLE` is enforced on-chain in {_grantRole},
    ///      not merely documented. An EOA holding this role could pull
    ///      treasury funds into a whitelisted pool and extract the LP.
    /// @param account The rejected EOA address.
    error POLDeployerMustBeContract(address account);

    /// @notice Thrown when a new non-zero approval would push the
    ///         tracked-approval array past `MAX_ACTIVE_APPROVALS`.
    /// @dev Audit M-08: call {revokeAllApprovals} to clear the array
    ///      before approving more spenders.
    error TooManyActiveApprovals();

    // ─────────────────────────── Constructor ─────────────────────────

    /**
     * @notice Deploy the OmniTreasuryV2 and grant initial roles.
     * @dev During Pioneer Phase the `admin` address holds
     *      DEFAULT_ADMIN_ROLE, GOVERNANCE_ROLE, and GUARDIAN_ROLE.
     *      `POL_DEPLOYER_ROLE` is intentionally NOT granted in the
     *      constructor — it is granted to the `POLManager` contract by
     *      `DEFAULT_ADMIN_ROLE` after both contracts are deployed.
     *      After the governance contracts are deployed the admin should
     *      grant roles to them and renounce its own via
     *      {transitionGovernance}.
     * @param admin The address that receives DEFAULT_ADMIN_ROLE,
     *              GOVERNANCE_ROLE, and GUARDIAN_ROLE.
     */
    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);
        // POL_DEPLOYER_ROLE is admined by DEFAULT_ADMIN_ROLE (the OZ
        // default for any role whose admin is not explicitly set).
    }

    // ───────────────────── Asset Reception ───────────────────────────

    /**
     * @notice Accept incoming native XOM transfers.
     * @dev Emits {NativeReceived}.
     */
    receive() external payable {
        emit NativeReceived(msg.sender, msg.value);
    }

    // ──────────────────── Governance Functions ───────────────────────

    /**
     * @notice Transfer ERC-20 tokens held by this contract.
     * @dev Uses SafeERC20 to handle non-standard return values.
     * @param token  The ERC-20 token to transfer.
     * @param to     The recipient address.
     * @param amount The amount to transfer.
     */
    function transferToken(
        IERC20 token,
        address to,
        uint256 amount
    )
        external
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (address(token) == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        token.safeTransfer(to, amount);

        emit TokenTransferred(address(token), to, amount);
    }

    /**
     * @notice Transfer native XOM held by this contract.
     * @param to     The recipient address (must accept XOM).
     * @param amount The amount of XOM to send (in wei).
     */
    function transferNative(
        address payable to,
        uint256 amount
    )
        external
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert NativeTransferFailed();

        emit NativeTransferred(to, amount);
    }

    /**
     * @notice Approve a spender for an ERC-20 token held by this
     *         contract.
     * @dev Uses SafeERC20.forceApprove to handle tokens that require
     *      resetting allowance to zero first.
     * @param token   The ERC-20 token to approve.
     * @param spender The address being approved.
     * @param amount  The allowance amount.
     */
    function approveToken(
        IERC20 token,
        address spender,
        uint256 amount
    )
        external
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (address(token) == address(0)) revert ZeroAddress();
        if (spender == address(0)) revert ZeroAddress();

        token.forceApprove(spender, amount);

        // M-01 Round 6: Track non-zero approvals for revocation.
        // M-08: bounded by MAX_ACTIVE_APPROVALS via _trackApproval.
        if (amount > 0) {
            _trackApproval(address(token), spender);
        } else {
            // Zeroing an approval removes it from active tracking (S-03).
            _removeApproval(address(token), spender);
        }

        emit TokenApproved(address(token), spender, amount);
    }

    /**
     * @notice Transfer an ERC-721 NFT held by this contract.
     * @param nft     The ERC-721 contract address.
     * @param to      The recipient address.
     * @param tokenId The token ID to transfer.
     */
    function transferNFT(
        address nft,
        address to,
        uint256 tokenId
    )
        external
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (nft == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();

        IERC721(nft).safeTransferFrom(address(this), to, tokenId);

        emit NFTTransferred(nft, to, tokenId);
    }

    /**
     * @notice Transfer ERC-1155 tokens held by this contract.
     * @param token  The ERC-1155 contract address.
     * @param to     The recipient address.
     * @param id     The token type ID.
     * @param amount The amount to transfer.
     * @param data   Additional data forwarded to the receiver hook.
     */
    function transferERC1155(
        address token,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    )
        external
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC1155(token).safeTransferFrom(
            address(this), to, id, amount, data
        );

        emit ERC1155Transferred(token, to, id, amount);
    }

    /**
     * @notice Execute an arbitrary low-level call. Useful for
     *         interacting with future contracts that do not yet exist.
     * @dev Only `call` is used — `delegatecall` is intentionally
     *      excluded to prevent storage corruption. The target cannot
     *      be `address(this)` to prevent self-call exploits.
     * @param target The contract address to call.
     * @param value  The native XOM to send with the call.
     * @param data   The calldata to forward.
     * @return returnData The bytes returned by the call.
     */
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    )
        external
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused
        nonReentrant
        returns (bytes memory returnData)
    {
        if (target == address(0)) revert ZeroAddress();
        if (target == address(this)) revert SelfCallNotAllowed();

        bool success;
        (success, returnData) = _callBounded(target, value, data);
        if (!success) revert ExecutionFailed(0, returnData);

        emit Executed(target, value, data);
    }

    /**
     * @notice Execute a batch of arbitrary low-level calls.
     * @dev Reverts on the first failure. All three arrays must have
     *      the same length. Emits one {Executed} per call in addition
     *      to the trailing {BatchExecuted}, so off-chain monitoring can
     *      reconstruct the batch from events alone (L-03 Round 7).
     * @param targets   The addresses to call.
     * @param values    The native XOM amounts for each call.
     * @param calldatas The calldata for each call.
     */
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    )
        external
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused
        nonReentrant
    {
        uint256 len = targets.length;
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge();
        if (len != values.length || len != calldatas.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i; i < len; ++i) {
            if (targets[i] == address(0)) revert ZeroAddress();
            if (targets[i] == address(this)) {
                revert SelfCallNotAllowed();
            }

            // solhint-disable-next-line avoid-low-level-calls
            (bool success, bytes memory ret) =
                _callBounded(targets[i], values[i], calldatas[i]);
            if (!success) revert ExecutionFailed(i, ret);

            // L-03 Round 7: per-call event for full event-only audit
            emit Executed(targets[i], values[i], calldatas[i]);
        }

        emit BatchExecuted(len);
    }

    // ──────────────────── POL Deployer Functions ─────────────────────

    /**
     * @notice Transfer ERC-20 tokens into a whitelisted POL pool target.
     * @dev Least-privilege analogue of {transferToken} scoped to the
     *      `POL_DEPLOYER_ROLE`. The `target` MUST be whitelisted via
     *      {setPOLTarget}; otherwise the call reverts with
     *      {POLTargetNotAllowed}. This lets the `POLManager` automation
     *      contract deploy treasury funds into pools (RWAAMM pools,
     *      OmniBonding, LiquidityMining) without holding the broad
     *      `GOVERNANCE_ROLE`.
     *
     *      Defense in depth: a transfer to `address(this)` is rejected
     *      even though {setPOLTarget} should never whitelist the
     *      treasury itself.
     * @param token  The ERC-20 token to transfer.
     * @param target The whitelisted POL pool to receive the tokens.
     * @param amount The amount to transfer.
     */
    function transferTokenToPOL(
        address token,
        address target,
        uint256 amount
    )
        external
        onlyRole(POL_DEPLOYER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (token == address(0)) revert ZeroAddress();
        if (target == address(this)) revert SelfCallNotAllowed();
        if (!polTargets[target]) revert POLTargetNotAllowed(target);
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransfer(target, amount);

        // Emit both the generic and POL-specific events so existing
        // off-chain indexers that watch TokenTransferred keep working.
        emit TokenTransferred(token, target, amount);
        emit POLTokenTransferred(token, target, amount);
    }

    /**
     * @notice Approve a whitelisted POL pool target to spend an ERC-20
     *         token held by this treasury.
     * @dev Least-privilege analogue of {approveToken} scoped to the
     *      `POL_DEPLOYER_ROLE`. The `target` MUST be whitelisted via
     *      {setPOLTarget}; otherwise the call reverts with
     *      {POLTargetNotAllowed}. Non-zero approvals are tracked in
     *      `_activeApprovals` so {revokeAllApprovals} and
     *      {transitionGovernance} clear them on governance handoff,
     *      exactly like {approveToken}.
     *
     *      Defense in depth: an approval to `address(this)` is rejected
     *      even though {setPOLTarget} should never whitelist the
     *      treasury itself.
     * @param token  The ERC-20 token to approve.
     * @param target The whitelisted POL pool granted the allowance.
     * @param amount The allowance amount.
     */
    function approveTokenForPOL(
        address token,
        address target,
        uint256 amount
    )
        external
        onlyRole(POL_DEPLOYER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (token == address(0)) revert ZeroAddress();
        if (target == address(this)) revert SelfCallNotAllowed();
        if (!polTargets[target]) revert POLTargetNotAllowed(target);

        IERC20(token).forceApprove(target, amount);

        // M-01 Round 6: Track non-zero approvals for revocation.
        // M-08: bounded by MAX_ACTIVE_APPROVALS via _trackApproval.
        if (amount > 0) {
            _trackApproval(token, target);
        } else {
            // Zeroing an approval removes it from active tracking (S-03).
            _removeApproval(token, target);
        }

        emit TokenApproved(token, target, amount);
        emit POLTokenApproved(token, target, amount);
    }

    // ───────────────────── Guardian Functions ────────────────────────

    /**
     * @notice Pause all governance and POL functions in an emergency.
     * @dev Only callable by GUARDIAN_ROLE.
     */
    function pause()
        external
        onlyRole(GUARDIAN_ROLE)
    {
        _pause();
    }

    /**
     * @notice Resume governance and POL functions after an emergency.
     * @dev Only callable by DEFAULT_ADMIN_ROLE. Separating unpause
     *      from pause prevents a compromised guardian from undoing
     *      its own emergency halt.
     */
    function unpause()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _unpause();
    }

    // ──────────────────── Approval Management ──────────────────────

    /**
     * @notice Revoke all tracked ERC-20 approvals (M-01 Round 6)
     * @dev Iterates over all approvals created via approveToken() or
     *      approveTokenForPOL() and sets each to zero via a best-effort
     *      `forceApprove`. Then clears the tracking array. Duplicates
     *      are harmless (forceApprove(0) is idempotent). Only
     *      GOVERNANCE_ROLE can call.
     */
    function revokeAllApprovals()
        external
        onlyRole(GOVERNANCE_ROLE)
        nonReentrant
    {
        _revokeAllApprovalsInternal();
    }

    // ──────────────────── Admin Functions ──────────────────────────

    /**
     * @notice Atomically transition all roles from the Pioneer Phase
     *         deployer to production governance contracts.
     * @dev Grants roles to the new holders first, then revokes the
     *      caller's roles in the correct order (governance, guardian,
     *      admin last). This prevents the misordered-renouncement
     *      attack where the deployer renounces admin before governance
     *      and becomes an irremovable governor.
     *
     *      Safe to call while paused — the new admin can unpause.
     *      If the caller does not hold a particular role, the revoke
     *      for that role is a no-op.
     *
     *      L-01 Round 7 fix: reverts if any new holder equals
     *      `msg.sender`. Handing a role back to the caller results in
     *      every role being revoked from every address (the grant is a
     *      no-op because the caller already holds the role, then the
     *      revoke removes it), permanently bricking the contract.
     *
     *      L-01 (this round): additionally reverts {DuplicateGovernanceTarget}
     *      if any two of `newGovernance`, `newGuardian`, `newAdmin` are
     *      the same address. The three roles must be distinct so the
     *      pause/unpause separation of powers is preserved.
     * @param newGovernance Address to receive GOVERNANCE_ROLE
     *                      (typically OmniTimelockController).
     * @param newGuardian   Address to receive GUARDIAN_ROLE
     *                      (typically EmergencyGuardian multi-sig).
     * @param newAdmin      Address to receive DEFAULT_ADMIN_ROLE
     *                      (typically OmniTimelockController).
     */
    function transitionGovernance(
        address newGovernance,
        address newGuardian,
        address newAdmin
    )
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newGovernance == address(0)) revert ZeroAddress();
        if (newGuardian == address(0)) revert ZeroAddress();
        if (newAdmin == address(0)) revert ZeroAddress();
        if (
            newGovernance == address(this) ||
            newGuardian == address(this) ||
            newAdmin == address(this)
        ) {
            revert InvalidGovernanceTarget();
        }
        // L-01 Round 7: reject self-transition — handing any role back
        // to the caller bricks the contract (see NatSpec above).
        if (
            newGovernance == msg.sender ||
            newGuardian == msg.sender ||
            newAdmin == msg.sender
        ) {
            revert CannotTransitionToSelf();
        }
        // L-01 (this round): the three roles must go to three distinct
        // addresses — collapsing them defeats the separation of powers.
        if (
            newGovernance == newGuardian ||
            newGovernance == newAdmin ||
            newGuardian == newAdmin
        ) {
            revert DuplicateGovernanceTarget();
        }

        // M-01 Round 6: Revoke all outstanding ERC-20 approvals
        // before transferring control to prevent stale approvals
        // from being exploited after governance transition.
        // M-03 Round 7: revocation is best-effort and cannot revert.
        _revokeAllApprovalsInternal();

        // Grant new roles first (admin first so _adminCount > 1
        // before revoking the caller's admin role)
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        _grantRole(GOVERNANCE_ROLE, newGovernance);
        _grantRole(GUARDIAN_ROLE, newGuardian);

        // Revoke caller's roles — governance and guardian first,
        // admin last (correct order)
        _revokeRole(GOVERNANCE_ROLE, msg.sender);
        _revokeRole(GUARDIAN_ROLE, msg.sender);
        _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);

        emit GovernanceTransitioned(
            newGovernance, newGuardian, newAdmin
        );
    }

    /**
     * @notice Add or remove a POL pool target from the `polTargets`
     *         allowlist.
     * @dev Only `DEFAULT_ADMIN_ROLE` may manage the allowlist —
     *      deliberately NOT `GOVERNANCE_ROLE`. Post-Pioneer-Phase the
     *      admin is `OmniTimelockController`, so every change is queued
     *      through the timelock before it can execute. The treasury
     *      itself can never be a valid target.
     *
     *      TIMELOCK TIER (audit H-05 — accurate classification):
     *      `setPOLTarget` designates an uncapped destination for
     *      `POL_DEPLOYER_ROLE` fund movements, so it is a CRITICAL
     *      change. However, `OmniTimelockController` classifies a call
     *      as critical (7-day `CRITICAL_DELAY`) ONLY when its 4-byte
     *      selector is in the timelock's critical-selector registry.
     *      The `setPOLTarget(address,bool)` selector is NOT one of the
     *      timelock's hardcoded critical selectors, so by default it
     *      would execute under the 48-hour `ROUTINE_DELAY`.
     *
     *      DEPLOY-TIME GOVERNANCE CONFIG (GOV-XSYS): the deployment
     *      runbook MUST register the `setPOLTarget` selector as critical
     *      via `OmniTimelockController.addCriticalSelector(<selector>)`
     *      before the governance handoff. Until that registration is
     *      executed, this function only carries the 48-hour delay. This
     *      contract cannot enforce the registration on-chain — it is a
     *      one-time governance configuration step, tracked alongside the
     *      other GOV-XSYS timelock-selector config items.
     * @param target  The POL pool address to add or remove.
     * @param allowed True to whitelist `target`, false to remove it.
     */
    function setPOLTarget(
        address target,
        bool allowed
    )
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (target == address(0)) revert ZeroAddress();
        if (target == address(this)) revert InvalidGovernanceTarget();

        polTargets[target] = allowed;

        emit POLTargetSet(target, allowed);
    }

    // ──────────────────────── View Functions ─────────────────────────

    /**
     * @notice Check the treasury's balance of an ERC-20 token.
     * @param token The ERC-20 token to query.
     * @return balance The token balance held by this contract.
     */
    function tokenBalance(
        IERC20 token
    ) external view returns (uint256 balance) {
        balance = token.balanceOf(address(this));
    }

    /**
     * @notice Check the treasury's native XOM balance.
     * @return balance The native XOM balance (in wei).
     */
    function nativeBalance()
        external
        view
        returns (uint256 balance)
    {
        balance = address(this).balance;
    }

    /**
     * @notice Check whether an address is a whitelisted POL target.
     * @param target The address to query.
     * @return allowed True if `target` is in the `polTargets` allowlist.
     */
    function isPOLTarget(
        address target
    ) external view returns (bool allowed) {
        allowed = polTargets[target];
    }

    /**
     * @notice Get the number of tracked active approvals.
     * @return count Number of tracked approvals.
     */
    function activeApprovalCount()
        external
        view
        returns (uint256 count)
    {
        count = _activeApprovals.length;
    }

    /**
     * @notice Get a tracked approval by index.
     * @param index Index in the approvals array.
     * @return token The ERC-20 token address.
     * @return spender The approved spender address.
     */
    function getActiveApproval(
        uint256 index
    )
        external
        view
        returns (address token, address spender)
    {
        Approval storage a = _activeApprovals[index];
        token = a.token;
        spender = a.spender;
    }

    // ──────────────────── Interface Support ──────────────────────────

    /**
     * @notice Declare supported interfaces (ERC-165).
     * @dev Combines AccessControl, ERC721Holder, and ERC1155Holder
     *      interface support.
     * @param interfaceId The 4-byte interface identifier.
     * @return supported True if the interface is supported.
     */
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(AccessControl, ERC1155Holder)
        returns (bool supported)
    {
        supported =
            interfaceId == type(IERC721Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ─────────────────── Internal Functions ────────────────────────

    /**
     * @notice Revoke all tracked ERC-20 approvals internally
     * @dev M-01 Round 6: Shared logic for revokeAllApprovals()
     *      and transitionGovernance().
     *
     *      M-03 Round 7 fix: each revocation is wrapped in a
     *      try/catch so a malicious or buggy token whose
     *      `approve(spender, 0)` reverts can no longer brick this
     *      loop — and therefore can no longer brick
     *      {transitionGovernance} or {revokeAllApprovals}. A failed
     *      revocation emits {ApprovalRevocationFailed} for off-chain
     *      monitoring; the residual allowance must then be cleared
     *      manually (e.g. via {approveToken} once the token behaves,
     *      or by the spender itself).
     *
     *      The low-level `IERC20.approve` is called directly rather
     *      than `SafeERC20.forceApprove` because `forceApprove`
     *      contains an internal require that itself reverts on
     *      non-compliant tokens, which would defeat the try/catch.
     *      `approve(spender, 0)` is the minimal, standard call; its
     *      boolean return value is intentionally ignored — a token
     *      that returns `false` instead of reverting still leaves a
     *      stale allowance, but that is the token misbehaving and is
     *      out of scope for a best-effort cleanup. The catch block
     *      handles the revert case, which is the documented M-03
     *      attack vector.
     */
    function _revokeAllApprovalsInternal() internal {
        uint256 len = _activeApprovals.length;
        for (uint256 i; i < len; ++i) {
            address token = _activeApprovals[i].token;
            address spender = _activeApprovals[i].spender;
            // M-03 Round 7: best-effort, revert-tolerant revocation.
            // slither-disable-next-line unchecked-lowlevel,calls-loop
            try IERC20(token).approve(spender, 0) {
                // Revocation succeeded — nothing more to do.
            } catch {
                emit ApprovalRevocationFailed(token, spender);
            }
        }
        delete _activeApprovals;
        emit AllApprovalsRevoked(len);
    }

    /**
     * @notice Append a tracked ERC-20 approval, enforcing the
     *         `MAX_ACTIVE_APPROVALS` cap.
     * @dev Audit M-08: shared push path for {approveToken} and
     *      {approveTokenForPOL}. Reverts {TooManyActiveApprovals} once
     *      the array is full so the `_revokeAllApprovalsInternal` loop
     *      can never exceed the block gas limit. A (token, spender) pair
     *      already tracked is skipped (S-02) so the array never holds
     *      duplicates.
     * @param token   The ERC-20 token whose approval is tracked.
     * @param spender The approved spender address.
     */
    function _trackApproval(address token, address spender) internal {
        // S-02: deduplicate so the same (token, spender) pair is tracked
        // exactly once.
        if (_isApprovalTracked(token, spender)) {
            return;
        }
        // solhint-disable-next-line gas-strict-inequalities
        if (_activeApprovals.length >= MAX_ACTIVE_APPROVALS) {
            revert TooManyActiveApprovals();
        }
        _activeApprovals.push(
            Approval({token: token, spender: spender})
        );
    }

    /**
     * @notice Check whether a (token, spender) pair is already tracked
     *         in `_activeApprovals`.
     * @param token The ERC-20 token address.
     * @param spender The approved spender address.
     * @return tracked True if the pair is already tracked.
     */
    function _isApprovalTracked(
        address token,
        address spender
    ) internal view returns (bool tracked) {
        uint256 len = _activeApprovals.length;
        for (uint256 i; i < len; ++i) {
            if (
                _activeApprovals[i].token == token &&
                _activeApprovals[i].spender == spender
            ) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Remove a (token, spender) pair from `_activeApprovals`
     *         via swap-with-last-and-pop.
     * @dev Shared by approveToken() / approveTokenForPOL() (zero-amount
     *      path) so the array cannot hold duplicates or stale zeroed
     *      entries.
     * @param token The ERC-20 token address.
     * @param spender The approved spender address.
     * @return removed True if an entry was found and removed.
     */
    function _removeApproval(
        address token,
        address spender
    ) internal returns (bool removed) {
        uint256 len = _activeApprovals.length;
        for (uint256 i; i < len; ++i) {
            if (
                _activeApprovals[i].token == token &&
                _activeApprovals[i].spender == spender
            ) {
                if (i != len - 1) {
                    _activeApprovals[i] = _activeApprovals[len - 1];
                }
                _activeApprovals.pop();
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Perform a low-level call and bound the return data copied
     *         to memory.
     * @dev Uses inline assembly so at most MAX_RETURN_DATA_LENGTH bytes
     *      are copied from the returndata, preventing a malicious target
     *      from forcing unbounded memory expansion (S-04).
     * @param target The contract to call.
     * @param value  The native XOM to send with the call.
     * @param data   The calldata to forward.
     * @return success Whether the call succeeded.
     * @return returnData The (bounded) bytes returned by the call.
     */
    function _callBounded(
        address target,
        uint256 value,
        bytes calldata data
    )
        internal
        returns (bool success, bytes memory returnData)
    {
        // Copy the calldata to memory so the low-level call forwards it
        // from a well-defined memory pointer (the input length is already
        // bounded by the transaction calldata size).
        bytes memory input = data;
        // solhint-disable-next-line avoid-low-level-calls
        assembly {
            success := call(gas(), target, value, add(input, 0x20), mload(input), 0, 0)
            let size := returndatasize()
            if gt(size, MAX_RETURN_DATA_LENGTH) {
                size := MAX_RETURN_DATA_LENGTH
            }
            returnData := mload(0x40)
            mstore(returnData, size)
            returndatacopy(add(returnData, 0x20), 0, size)
            mstore(
                0x40,
                add(add(returnData, 0x20), and(add(size, 0x1f), not(0x1f)))
            )
        }
    }

    // ─────────────────── Internal Overrides ───────────────────────

    /**
     * @notice Track `_adminCount` and enforce the `POL_DEPLOYER_ROLE`
     *         contract-only invariant when roles are granted.
     * @dev Overrides AccessControl to keep `_adminCount` in sync and to
     *      reject any `POL_DEPLOYER_ROLE` grant to an EOA (audit M-03).
     *      The `account.code.length > 0` check holds in practice because
     *      `POLManager` is always deployed before the role is granted to
     *      it; a contract still under construction has zero code length
     *      and would be rejected, which is the intended conservative
     *      behavior for this treasury role.
     * @param role The role being granted.
     * @param account The account receiving the role.
     * @return granted True if the role was newly granted.
     */
    function _grantRole(
        bytes32 role,
        address account
    ) internal override returns (bool granted) {
        // M-03: POL_DEPLOYER_ROLE must only ever be held by a contract.
        if (role == POL_DEPLOYER_ROLE && account.code.length == 0) {
            revert POLDeployerMustBeContract(account);
        }

        granted = super._grantRole(role, account);
        if (granted && role == DEFAULT_ADMIN_ROLE) {
            ++_adminCount;
        }
    }

    /**
     * @notice Track `_adminCount` when DEFAULT_ADMIN_ROLE is revoked.
     * @dev Always prevents removing the last admin to avoid
     *      permanently bricking the treasury. Additionally reverts
     *      with a more specific error when paused, since the
     *      treasury would be unrecoverable without an admin to
     *      call `unpause()`.
     * @param role The role being revoked.
     * @param account The account losing the role.
     * @return revoked True if the role was actually revoked.
     */
    function _revokeRole(
        bytes32 role,
        address account
    ) internal override returns (bool revoked) {
        if (
            role == DEFAULT_ADMIN_ROLE &&
            hasRole(role, account) &&
            _adminCount == 1
        ) {
            if (paused()) {
                revert CannotRemoveLastAdminWhilePaused();
            }
            revert CannotRemoveLastAdmin();
        }

        revoked = super._revokeRole(role, account);
        if (revoked && role == DEFAULT_ADMIN_ROLE) {
            --_adminCount;
        }
    }
}
