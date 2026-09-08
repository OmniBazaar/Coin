// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OmniAgentPermissions
 * @notice Scoped, revocable, on-chain-enforced delegated-spend authority for AI
 *         agents acting with a user's self-custodied wallet (ADD_AGENTIC.md §2.3).
 *
 *         A user (grant OWNER) signs an EIP-712 `Grant` binding a dedicated agent
 *         keypair to: a feature-scope bitmask, per-token spend caps (per-tx /
 *         rolling-daily / lifetime), a counterparty allowlist, and a validity
 *         window. The grant is registered by anyone carrying the owner's
 *         signature (in practice the gasless relayer). The ONLY fund-moving path
 *         is {executeWithPermission}: the agent signs an EIP-712 `PaymentIntent`
 *         and funds move DIRECTLY owner -> payTo (+ fee -> fee vault) via
 *         `transferFrom`. This contract never holds a balance (non-custodial).
 *
 *         Revocation is instant, idempotent, irreversible, and available both to
 *         `_msgSender() == owner` (ERC-2771-aware, so gasless via OmniForwarder)
 *         and by owner signature.
 *
 *         Pioneer-phase admin: the deployer EOA owns the contract directly; the
 *         only admin surface is {setFeeVault}. No delays, no timelocks.
 *
 * @dev SECURITY REVIEW REQUIRED (ADD_AGENTIC.md §7) before any mainnet use.
 */
contract OmniAgentPermissions is ERC2771Context, Ownable, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice Per-token spending caps supplied at grant registration.
    struct TokenCapInput {
        address token;
        uint256 perTxCap;
        uint256 dailyCap;
        uint256 lifetimeCap;
    }

    /// @notice Full grant parameters signed by the owner (EIP-712 `Grant`).
    struct GrantParams {
        address owner;
        address agentKey;
        uint32 featureScopeMask;
        uint48 validAfter;
        uint48 validUntil;
        bytes32 salt;
        TokenCapInput[] tokenCaps;
        address[] counterparties;
    }

    /// @notice Registered grant core state.
    struct AgentGrant {
        address owner;
        address agentKey;
        uint48 validAfter;
        uint48 validUntil;
        bool revoked;
        uint32 featureScopeMask;
    }

    /// @notice Live per-token cap accounting.
    struct TokenCap {
        bool allowed;
        uint256 perTxCap;
        uint256 dailyCap;
        uint256 lifetimeCap;
        uint256 spentToday;
        uint48 dayStart;
        uint256 spentTotal;
    }

    /// @notice Payment authorization signed by the AGENT key (EIP-712 `PaymentIntent`).
    struct PaymentIntent {
        bytes32 grantId;
        address token;
        uint256 amount;
        address payTo;
        uint256 feeAmount;
        address feeRecipient;
        uint8 featureCode;
        bytes32 nonce;
        uint256 deadline;
    }

    /**
     * @notice Scope bits that may NEVER be granted to agents — the on-chain
     *         backstop for the regulatory boundary (ADD_AGENTIC.md §2.6):
     *         bit 3 = predictions.trade, bit 4 = rwa.buy. Enforced at both
     *         {registerGrant} (a grant carrying these bits cannot be registered)
     *         and {executeWithPermission} (a payment on these codes cannot
     *         settle), so the geofence no longer rests solely on off-chain code.
     */
    uint32 public constant RESTRICTED_SCOPE_MASK =
        (uint32(1) << 3) | (uint32(1) << 4);

    // ---------------------------------------------------------------------
    // EIP-712 type hashes
    // ---------------------------------------------------------------------

    bytes32 public constant TOKEN_CAP_TYPEHASH = keccak256(
        "TokenCapInput(address token,uint256 perTxCap,uint256 dailyCap,uint256 lifetimeCap)"
    );

    bytes32 public constant GRANT_TYPEHASH = keccak256(
        // solhint-disable-next-line max-line-length
        "Grant(address owner,address agentKey,uint32 featureScopeMask,uint48 validAfter,uint48 validUntil,bytes32 salt,TokenCapInput[] tokenCaps,address[] counterparties)TokenCapInput(address token,uint256 perTxCap,uint256 dailyCap,uint256 lifetimeCap)"
    );

    bytes32 public constant REVOKE_TYPEHASH = keccak256("RevokeGrant(bytes32 grantId)");

    bytes32 public constant PAYMENT_INTENT_TYPEHASH = keccak256(
        // solhint-disable-next-line max-line-length
        "PaymentIntent(bytes32 grantId,address token,uint256 amount,address payTo,uint256 feeAmount,address feeRecipient,uint8 featureCode,bytes32 nonce,uint256 deadline)"
    );

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice Fee-leg recipient enforced on every payment (UnifiedFeeVault in production).
    address public feeVault;

    /// @notice grantId => grant core state.
    mapping(bytes32 => AgentGrant) private _grants;

    /// @notice grantId => token => live cap accounting.
    mapping(bytes32 => mapping(address => TokenCap)) private _tokenCaps;

    /// @notice grantId => counterparty => allowed.
    mapping(bytes32 => mapping(address => bool)) public allowedCounterparties;

    /// @notice grantId => intent nonce => used (unordered, EIP-3009-style).
    mapping(bytes32 => mapping(bytes32 => bool)) public usedNonces;

    /// @notice grantId => token list (enumeration for UIs).
    mapping(bytes32 => address[]) private _grantTokens;

    /// @notice grantId => counterparty list (enumeration for UIs).
    mapping(bytes32 => address[]) private _grantCounterparties;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event GrantRegistered(
        bytes32 indexed grantId,
        address indexed owner,
        address indexed agentKey,
        uint32 featureScopeMask,
        uint48 validAfter,
        uint48 validUntil
    );
    event GrantRevoked(bytes32 indexed grantId, address indexed owner);
    event PaymentExecuted(
        bytes32 indexed grantId,
        address indexed token,
        address indexed payTo,
        uint256 amount,
        uint256 feeAmount,
        uint8 featureCode,
        bytes32 nonce
    );
    event FeeVaultChanged(address indexed previousVault, address indexed newVault);

    // ---------------------------------------------------------------------
    // Errors (ADD_AGENTIC.md §2.3 failure modes)
    // ---------------------------------------------------------------------

    error GrantNotFound();
    error GrantAlreadyRegistered();
    error GrantRevokedError();
    error GrantNotYetValid();
    error GrantExpired();
    error FeatureNotGranted();
    error RestrictedScope();
    error TokenNotAllowed();
    error PerTxCapExceeded();
    error DailyCapExceeded();
    error LifetimeCapExceeded();
    error CounterpartyNotAllowed();
    error BadFeeRecipient();
    error NonceAlreadyUsed();
    error IntentExpired();
    error BadAgentSignature();
    error BadOwnerSignature();
    error NotGrantOwner();
    error InvalidGrantParams();
    error ZeroAddress();

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    /**
     * @param trustedForwarder OmniForwarder (ERC-2771) address for gasless calls.
     * @param feeVault_ Fee-leg recipient (UnifiedFeeVault in production).
     * @param initialOwner Deployer EOA (Pioneer-phase direct admin).
     */
    constructor(
        address trustedForwarder,
        address feeVault_,
        address initialOwner
    )
        ERC2771Context(trustedForwarder)
        Ownable(initialOwner)
        EIP712("OmniAgentPermissions", "1")
    {
        if (feeVault_ == address(0)) revert ZeroAddress();
        feeVault = feeVault_;
    }

    // ---------------------------------------------------------------------
    // Admin (deployer-direct, Pioneer phase)
    // ---------------------------------------------------------------------

    /**
     * @notice Update the enforced fee-leg recipient.
     * @param newVault The new fee vault address.
     */
    function setFeeVault(address newVault) external onlyOwner {
        if (newVault == address(0)) revert ZeroAddress();
        emit FeeVaultChanged(feeVault, newVault);
        feeVault = newVault;
    }

    // ---------------------------------------------------------------------
    // Grant lifecycle
    // ---------------------------------------------------------------------

    /**
     * @notice Register a grant carrying the owner's EIP-712 signature. Anyone
     *         may submit (in practice the gasless relayer does).
     * @param p Full grant parameters (must match what the owner signed).
     * @param ownerSig Owner's EIP-712 signature over `Grant(...)`.
     * @return grantId The unique id (EIP-712 digest) of the registered grant.
     */
    function registerGrant(
        GrantParams calldata p,
        bytes calldata ownerSig
    ) external nonReentrant returns (bytes32 grantId) {
        if (p.owner == address(0) || p.agentKey == address(0)) revert ZeroAddress();
        if (p.validUntil <= block.timestamp || p.validUntil <= p.validAfter) {
            revert InvalidGrantParams();
        }
        if (p.tokenCaps.length == 0 || p.counterparties.length == 0) {
            revert InvalidGrantParams();
        }
        // Regulatory backstop: a grant carrying a restricted vertical bit
        // (predictions / RWA) can never be registered on-chain.
        if (p.featureScopeMask & RESTRICTED_SCOPE_MASK != 0) revert RestrictedScope();

        grantId = _hashGrant(p);
        if (_grants[grantId].owner != address(0)) revert GrantAlreadyRegistered();

        address recovered = ECDSA.recover(grantId, ownerSig);
        if (recovered != p.owner) revert BadOwnerSignature();

        _grants[grantId] = AgentGrant({
            owner: p.owner,
            agentKey: p.agentKey,
            validAfter: p.validAfter,
            validUntil: p.validUntil,
            revoked: false,
            featureScopeMask: p.featureScopeMask
        });

        for (uint256 i = 0; i < p.tokenCaps.length; i++) {
            TokenCapInput calldata c = p.tokenCaps[i];
            if (c.token == address(0)) revert ZeroAddress();
            if (c.perTxCap == 0 || c.perTxCap > c.dailyCap || c.dailyCap > c.lifetimeCap) {
                revert InvalidGrantParams();
            }
            if (_tokenCaps[grantId][c.token].allowed) revert InvalidGrantParams();
            _tokenCaps[grantId][c.token] = TokenCap({
                allowed: true,
                perTxCap: c.perTxCap,
                dailyCap: c.dailyCap,
                lifetimeCap: c.lifetimeCap,
                spentToday: 0,
                // Rolling 24h window anchored at the first spend (0 = unstarted).
                dayStart: 0,
                spentTotal: 0
            });
            _grantTokens[grantId].push(c.token);
        }

        for (uint256 i = 0; i < p.counterparties.length; i++) {
            address cp = p.counterparties[i];
            if (cp == address(0)) revert ZeroAddress();
            if (allowedCounterparties[grantId][cp]) revert InvalidGrantParams();
            allowedCounterparties[grantId][cp] = true;
            _grantCounterparties[grantId].push(cp);
        }

        emit GrantRegistered(
            grantId, p.owner, p.agentKey, p.featureScopeMask, p.validAfter, p.validUntil
        );
    }

    /**
     * @notice Revoke a grant. Caller must be the grant owner (ERC-2771-aware,
     *         so callable gaslessly through OmniForwarder). Idempotent.
     * @param grantId The grant to revoke.
     */
    function revokeGrant(bytes32 grantId) external nonReentrant {
        AgentGrant storage g = _grants[grantId];
        if (g.owner == address(0)) revert GrantNotFound();
        if (_msgSender() != g.owner) revert NotGrantOwner();
        _revoke(grantId, g);
    }

    /**
     * @notice Revoke a grant by owner signature (submittable by anyone).
     *         Idempotent; revocation is irreversible so signature replay is harmless.
     * @param grantId The grant to revoke.
     * @param ownerSig Owner's EIP-712 signature over `RevokeGrant(grantId)`.
     */
    function revokeGrantBySig(bytes32 grantId, bytes calldata ownerSig) external nonReentrant {
        AgentGrant storage g = _grants[grantId];
        if (g.owner == address(0)) revert GrantNotFound();
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(REVOKE_TYPEHASH, grantId))
        );
        if (ECDSA.recover(digest, ownerSig) != g.owner) revert BadOwnerSignature();
        _revoke(grantId, g);
    }

    // ---------------------------------------------------------------------
    // Payment execution — the ONLY fund-moving path
    // ---------------------------------------------------------------------

    /**
     * @notice Execute an agent-signed payment within a grant's scope. Funds move
     *         directly owner -> payTo and owner -> feeVault; this contract never
     *         holds a balance. Reverts with a typed error on any scope violation.
     * @param intent The agent-signed payment intent.
     * @param agentSig Agent key's EIP-712 signature over `PaymentIntent(...)`.
     */
    function executeWithPermission(
        PaymentIntent calldata intent,
        bytes calldata agentSig
    ) external nonReentrant {
        AgentGrant storage g = _grants[intent.grantId];
        if (g.owner == address(0)) revert GrantNotFound();
        if (g.revoked) revert GrantRevokedError();
        if (block.timestamp < g.validAfter) revert GrantNotYetValid();
        if (block.timestamp > g.validUntil) revert GrantExpired();
        if (block.timestamp > intent.deadline) revert IntentExpired();
        // Restricted verticals (predictions / RWA) can never settle, even if
        // a grant somehow carried the bit — on-chain regulatory backstop.
        if (RESTRICTED_SCOPE_MASK & (uint32(1) << intent.featureCode) != 0) {
            revert RestrictedScope();
        }
        if ((g.featureScopeMask & (uint32(1) << intent.featureCode)) == 0) {
            revert FeatureNotGranted();
        }

        TokenCap storage cap = _tokenCaps[intent.grantId][intent.token];
        if (!cap.allowed) revert TokenNotAllowed();

        uint256 total = intent.amount + intent.feeAmount;
        if (total > cap.perTxCap) revert PerTxCapExceeded();

        // Rolling 24h window: reset the daily tally when the window is unstarted
        // or a full day has elapsed since it was anchored. Anchoring at the
        // first spend (not at UTC midnight) closes the calendar-boundary
        // doubling where dailyCap could be spent just before midnight and again
        // just after (ADD_AGENTIC.md §7 finding M1).
        if (cap.dayStart == 0 || block.timestamp - cap.dayStart >= 1 days) {
            cap.dayStart = uint48(block.timestamp);
            cap.spentToday = 0;
        }
        if (cap.spentToday + total > cap.dailyCap) revert DailyCapExceeded();
        if (cap.spentTotal + total > cap.lifetimeCap) revert LifetimeCapExceeded();

        if (!allowedCounterparties[intent.grantId][intent.payTo]) {
            revert CounterpartyNotAllowed();
        }
        if (intent.feeRecipient != feeVault) revert BadFeeRecipient();
        if (usedNonces[intent.grantId][intent.nonce]) revert NonceAlreadyUsed();

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    PAYMENT_INTENT_TYPEHASH,
                    intent.grantId,
                    intent.token,
                    intent.amount,
                    intent.payTo,
                    intent.feeAmount,
                    intent.feeRecipient,
                    intent.featureCode,
                    intent.nonce,
                    intent.deadline
                )
            )
        );
        if (ECDSA.recover(digest, agentSig) != g.agentKey) revert BadAgentSignature();

        // Effects before interactions.
        usedNonces[intent.grantId][intent.nonce] = true;
        cap.spentToday += total;
        cap.spentTotal += total;

        IERC20 token = IERC20(intent.token);
        token.safeTransferFrom(g.owner, intent.payTo, intent.amount);
        if (intent.feeAmount > 0) {
            token.safeTransferFrom(g.owner, intent.feeRecipient, intent.feeAmount);
        }

        emit PaymentExecuted(
            intent.grantId,
            intent.token,
            intent.payTo,
            intent.amount,
            intent.feeAmount,
            intent.featureCode,
            intent.nonce
        );
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /**
     * @notice Read a grant's core state.
     * @param grantId The grant id.
     * @return The grant core state (owner == address(0) means not registered).
     */
    function getGrant(bytes32 grantId) external view returns (AgentGrant memory) {
        return _grants[grantId];
    }

    /**
     * @notice Enumerate a grant's allowed tokens and counterparties (UI support).
     * @param grantId The grant id.
     * @return tokens Allowed token addresses.
     * @return counterparties Allowed counterparty addresses.
     */
    function getGrantLists(
        bytes32 grantId
    ) external view returns (address[] memory tokens, address[] memory counterparties) {
        return (_grantTokens[grantId], _grantCounterparties[grantId]);
    }

    /**
     * @notice Remaining spend headroom for a grant/token pair, accounting for a
     *         not-yet-rolled daily window.
     * @param grantId The grant id.
     * @param token The token address.
     * @return perTx Per-transaction cap.
     * @return remainingToday Remaining daily headroom.
     * @return remainingLifetime Remaining lifetime headroom.
     */
    function remainingCaps(
        bytes32 grantId,
        address token
    ) external view returns (uint256 perTx, uint256 remainingToday, uint256 remainingLifetime) {
        TokenCap storage cap = _tokenCaps[grantId][token];
        if (!cap.allowed) return (0, 0, 0);
        bool windowElapsed =
            cap.dayStart == 0 || block.timestamp - cap.dayStart >= 1 days;
        uint256 spentToday = windowElapsed ? 0 : cap.spentToday;
        perTx = cap.perTxCap;
        remainingToday = cap.dailyCap > spentToday ? cap.dailyCap - spentToday : 0;
        remainingLifetime =
            cap.lifetimeCap > cap.spentTotal ? cap.lifetimeCap - cap.spentTotal : 0;
    }

    /**
     * @notice Compute the grant id (EIP-712 digest) for given parameters. This is
     *         also the digest the owner signs to authorize registration.
     * @param p The grant parameters.
     * @return The grant id / signing digest.
     */
    function hashGrant(GrantParams calldata p) external view returns (bytes32) {
        return _hashGrant(p);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev EIP-712 digest of a Grant struct (doubles as the grant id).
    function _hashGrant(GrantParams calldata p) internal view returns (bytes32) {
        bytes32[] memory capHashes = new bytes32[](p.tokenCaps.length);
        for (uint256 i = 0; i < p.tokenCaps.length; i++) {
            TokenCapInput calldata c = p.tokenCaps[i];
            capHashes[i] = keccak256(
                abi.encode(TOKEN_CAP_TYPEHASH, c.token, c.perTxCap, c.dailyCap, c.lifetimeCap)
            );
        }
        bytes32 structHash = keccak256(
            abi.encode(
                GRANT_TYPEHASH,
                p.owner,
                p.agentKey,
                p.featureScopeMask,
                p.validAfter,
                p.validUntil,
                p.salt,
                keccak256(abi.encodePacked(capHashes)),
                keccak256(abi.encodePacked(p.counterparties))
            )
        );
        return _hashTypedDataV4(structHash);
    }

    /// @dev Shared revocation effect (idempotent).
    function _revoke(bytes32 grantId, AgentGrant storage g) internal {
        if (!g.revoked) {
            g.revoked = true;
            emit GrantRevoked(grantId, g.owner);
        }
    }

    // ---------------------------------------------------------------------
    // ERC-2771 / Context plumbing
    // ---------------------------------------------------------------------

    /// @dev Resolve Context vs ERC2771Context multiple inheritance.
    function _msgSender() internal view override(Context, ERC2771Context) returns (address) {
        return ERC2771Context._msgSender();
    }

    /// @dev Resolve Context vs ERC2771Context multiple inheritance.
    function _msgData()
        internal
        view
        override(Context, ERC2771Context)
        returns (bytes calldata)
    {
        return ERC2771Context._msgData();
    }

    /// @dev Resolve Context vs ERC2771Context multiple inheritance.
    function _contextSuffixLength()
        internal
        view
        override(Context, ERC2771Context)
        returns (uint256)
    {
        return ERC2771Context._contextSuffixLength();
    }
}
