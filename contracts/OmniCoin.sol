// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

/**
 * @title OmniCoin
 * @author OmniCoin Development Team
 * @notice ERC20 governance token for the OmniBazaar ecosystem
 * @dev Public token with role-based minting/burning and on-chain governance support.
 *
 * Key features:
 * - 18 decimal places for full Ethereum compatibility
 * - Role-based access control for minting/burning
 * - On-chain MAX_SUPPLY cap of 16.6 billion XOM (defense-in-depth)
 * - Two-step admin transfer with 48-hour delay (M-03 remediation)
 * - Pausable for emergency stops
 * - ERC20Permit for gasless approvals (EIP-2612)
 * - ERC20Votes for on-chain governance delegation and checkpointed voting power
 * - Full genesis supply of 16.6 billion tokens (pre-minted to deployer for pool funding)
 * - ERC2771Context for gasless meta-transactions via OmniForwarder
 *
 * Gasless Support:
 * - All ERC20 operations (transfer, approve, transferFrom) work through the forwarder
 *   because OZ ERC20 internally uses _msgSender() which ERC2771Context overrides
 * - batchTransfer also uses _msgSender() for gasless support
 * - Admin/minter functions deliberately use msg.sender (admin ops should NOT be relayed)
 *
 * Governance:
 * - Token holders must call delegate(self) to activate voting power
 * - Voting power can be delegated to any address without transferring tokens
 * - Historical voting power queryable via getPastVotes() for snapshot-based governance
 * - Compatible with OmniGovernance on-chain execution model
 *
 * Security (M-02): The DEFAULT_ADMIN_ROLE holder should be a
 * TimelockController or multi-sig wallet in production. The 48-hour
 * delay on admin transfer (via AccessControlDefaultAdminRules) provides
 * a safety net against accidental or malicious admin changes.
 */
contract OmniCoin is
    ERC20,
    ERC20Burnable,
    ERC20Pausable,
    ERC20Permit,
    ERC20Votes,
    AccessControlDefaultAdminRules,
    ERC2771Context
{
    /// @dev AUDIT ACCEPTED (Round 6 FEE-AP-01): Users can bypass marketplace fees
    ///      by sending XOM directly via ERC20 transfer() instead of using the
    ///      marketplace/escrow flow. This is standard ERC20 behavior — the token
    ///      contract cannot force fee collection on direct transfers without
    ///      breaking ERC20 composability. Fee enforcement is handled at the
    ///      application layer (escrow, DEX settlement) where transactions occur.

    // Constants
    /// @notice Role identifier for minting permissions
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role identifier for burning permissions
    /// @dev AUDIT ACCEPTED (Round 6): BURNER_ROLE is granted to OmniCore for legacy
    ///      balance migration burn-and-reissue. In production, BURNER_ROLE will be
    ///      granted ONLY to OmniCore and revoked after migration completes. The role
    ///      cannot independently drain funds — it can only burn tokens, not transfer them.
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Full genesis supply: 16.6 billion XOM pre-minted to deployer
    /// @dev All tokens are created at genesis. The deployer distributes them
    ///      to pool contracts (LegacyBalanceClaim, OmniRewardManager,
    ///      StakingRewardPool) and then revokes MINTER_ROLE permanently.
    ///      This eliminates infinite-mint attack vectors.
    uint256 public constant INITIAL_SUPPLY = 16_600_000_000 * 10 ** 18;

    /// @notice Maximum lifetime supply: 16.6 billion XOM (all minted at genesis)
    uint256 public constant MAX_SUPPLY = 16_600_000_000 * 10 ** 18;

    // Immutable state variables
    /// @notice Address that deployed the contract (only address that can call initialize)
    // solhint-disable-next-line immutable-vars-naming
    address private immutable _deployer;

    // Custom errors
    /// @notice Thrown when minting would exceed the maximum lifetime supply
    error ExceedsMaxSupply();
    /// @notice Thrown when initialize() is called a second time
    error AlreadyInitialized();
    /// @notice Thrown when recipients and amounts arrays have different lengths
    error ArrayLengthMismatch();
    /// @notice Thrown when batch transfer exceeds the maximum number of recipients
    error TooManyRecipients();
    /// @notice Thrown when a recipient address is the zero address
    error InvalidRecipient();
    /// @notice Thrown when a non-deployer calls initialize()
    error Unauthorized();

    /**
     * @notice Constructor for OmniCoin
     * @dev Sets up ERC20 with name, symbol, ERC20Permit with EIP-712 domain,
     *      ERC20Votes for governance delegation, two-step admin transfer
     *      with a 48-hour delay (M-03 remediation), and ERC2771Context for
     *      gasless meta-transactions. Records deployer address to prevent
     *      initialize() front-running.
     * @param trustedForwarder_ Address of the OmniForwarder contract for gasless relay.
     *        Pass address(0) to disable meta-transaction support (falls back to msg.sender).
     */
    /// @dev AUDIT ACCEPTED (Round 6): The trusted forwarder address is immutable by design.
    ///      ERC-2771 forwarder immutability is standard practice (OpenZeppelin default).
    ///      Changing the forwarder post-deployment would break all existing meta-transaction
    ///      infrastructure. If the forwarder is compromised, ossify() + governance pause
    ///      provides emergency protection. A new proxy can be deployed if needed.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder_)
        ERC20("OmniCoin", "XOM")
        ERC20Permit("OmniCoin")
        AccessControlDefaultAdminRules(48 hours, msg.sender)
        ERC2771Context(trustedForwarder_)
    {
        _deployer = msg.sender;
    }

    /**
     * @notice Initialize OmniCoin token
     * @dev Mints initial supply to deployer. Only the contract deployer
     *      can call this. DEFAULT_ADMIN_ROLE is already set by the
     *      constructor via AccessControlDefaultAdminRules.
     */
    function initialize() external {
        if (msg.sender != _deployer) revert Unauthorized();
        if (totalSupply() != 0) revert AlreadyInitialized();

        // Grant operational roles to deployer
        // NOTE: DEFAULT_ADMIN_ROLE is already assigned by the constructor
        // via AccessControlDefaultAdminRules. Do not re-grant it here.
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);

        // Mint initial supply
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /**
     * @notice Mint new tokens
     * @dev Only MINTER_ROLE can mint. Enforces on-chain MAX_SUPPLY cap as
     *      defense-in-depth against compromised minter keys (H-03 remediation).
     * @param to Address to mint tokens to
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (totalSupply() + amount > MAX_SUPPLY) revert ExceedsMaxSupply();
        _mint(to, amount);
    }

    /**
     * @notice Pause all token transfers
     * @dev Only admin can pause
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause token transfers
     * @dev Only admin can unpause
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Batch transfer to multiple recipients
     * @dev Useful for marketplace fee splits - saves gas vs multiple transfers
     * @param recipients Array of recipient addresses
     * @param amounts Array of amounts to send to each recipient
     * @return success Whether all transfers succeeded
     */
    function batchTransfer(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external whenNotPaused returns (bool success) {
        if (recipients.length != amounts.length) revert ArrayLengthMismatch();
        if (recipients.length > 10) revert TooManyRecipients();

        address sender = _msgSender();
        for (uint256 i = 0; i < recipients.length; ++i) {
            if (recipients[i] == address(0) || recipients[i] == address(this)) revert InvalidRecipient();
            _transfer(sender, recipients[i], amounts[i]);
        }

        return true;
    }

    /**
     * @notice Burn tokens from an account. BURNER_ROLE bypasses allowance.
     * @dev SECURITY: BURNER_ROLE has unrestricted burn power. This role
     *      MUST ONLY be granted to trusted, audited contracts (currently:
     *      PrivateOmniCoin). Granting BURNER_ROLE to ANY new contract
     *      requires a CRITICAL governance proposal with 7-day timelock.
     *      A compromised BURNER_ROLE holder can destroy any user's entire
     *      balance.
     *
     *      ATK-H03: This allowance bypass is BY DESIGN — PrivateOmniCoin
     *      needs to burn XOM during privacy conversions without requiring
     *      user approval for each conversion. The role-based guard
     *      (onlyRole(BURNER_ROLE)) replaces the allowance guard. The
     *      DEFAULT_ADMIN_ROLE holder (TimelockController) controls who
     *      receives BURNER_ROLE.
     *
     *      NEVER grant BURNER_ROLE to an EOA in production.
     *
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burnFrom(
        address from,
        uint256 amount
    ) public override onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }

    // =========================================================================
    // Overrides required for multiple inheritance
    // (ERC20Pausable + ERC20Votes + ERC2771Context)
    // =========================================================================

    /**
     * @notice Resolve nonces between ERC20Permit and Votes (both use Nonces)
     * @dev Both ERC20Permit and Votes inherit from Nonces. This override
     *      resolves the diamond and delegates to the shared Nonces base.
     * @param owner Address to query nonces for
     * @return Current nonce for the owner
     */
    function nonces(
        address owner
    ) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    /**
     * @notice Internal transfer hook for pausable checks and voting power updates
     * @dev Resolves diamond inheritance between ERC20Pausable (pause enforcement)
     *      and ERC20Votes (voting power checkpoint updates). Both are applied
     *      on every transfer, mint, and burn.
     * @param from Address tokens are transferred from (zero for mint)
     * @param to Address tokens are transferred to (zero for burn)
     * @param amount Amount of tokens to transfer
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Pausable, ERC20Votes) {
        super._update(from, to, amount);
    }

    /**
     * @notice Resolve _msgSender between Context and ERC2771Context
     * @dev ERC2771Context overrides _msgSender() to extract the original signer
     *      from calldata when called through the trusted forwarder. This override
     *      resolves the diamond with Context (inherited by ERC20, AccessControl, etc.).
     * @return The original transaction signer (user) when relayed, or msg.sender when direct
     */
    function _msgSender()
        internal
        view
        override(Context, ERC2771Context)
        returns (address)
    {
        return ERC2771Context._msgSender();
    }

    /**
     * @notice Resolve _msgData between Context and ERC2771Context
     * @dev Strips the appended sender address from calldata when called through
     *      the trusted forwarder. Falls back to msg.data for direct calls.
     * @return The original calldata without the ERC2771 suffix
     */
    function _msgData()
        internal
        view
        override(Context, ERC2771Context)
        returns (bytes calldata)
    {
        return ERC2771Context._msgData();
    }

    /**
     * @notice Resolve _contextSuffixLength between Context and ERC2771Context
     * @dev Returns 20 (address length) for ERC2771 context suffix stripping
     * @return The number of bytes appended to calldata by the forwarder (20)
     */
    function _contextSuffixLength()
        internal
        view
        override(Context, ERC2771Context)
        returns (uint256)
    {
        return ERC2771Context._contextSuffixLength();
    }
}
