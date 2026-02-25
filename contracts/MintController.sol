// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title IOmniCoinMintable
 * @author OmniCoin Development Team
 * @notice Typed interface for OmniCoin minting, extending IERC20
 * @dev Avoids unsafe low-level calls by providing compile-time
 *      function signature verification.
 */
interface IOmniCoinMintable is IERC20 {
    /// @notice Mint new tokens to a recipient
    /// @param to Recipient address
    /// @param amount Amount to mint
    function mint(address to, uint256 amount) external;
}

/**
 * @title MintController
 * @author OmniCoin Development Team
 * @notice Enforces a hard supply cap on OmniCoin (XOM) minting
 * @dev Wraps OmniCoin's mint() function with an immutable MAX_SUPPLY check.
 *
 * Deployment model:
 *   1. Deploy MintController with the OmniCoin token address
 *   2. Grant MINTER_ROLE on OmniCoin to this MintController
 *   3. Revoke MINTER_ROLE from the deployer on OmniCoin
 *   4. All future minting flows through this contract
 *
 * The MAX_SUPPLY constant (16.6 billion XOM) matches published tokenomics.
 * Once totalSupply() reaches this cap, no further minting is possible —
 * there is no admin override, upgrade path, or emergency bypass.
 */
contract MintController is AccessControl, Pausable, ReentrancyGuard {
    // ──────────────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Role identifier for addresses authorized to mint via this controller
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role identifier for addresses authorized to pause/unpause minting
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Maximum total supply of XOM tokens (16.6 billion with 18 decimals)
    uint256 public constant MAX_SUPPLY = 16_600_000_000e18;

    /// @notice Duration of a rate-limiting epoch (1 hour)
    uint256 public constant EPOCH_DURATION = 1 hours;

    /// @notice Maximum tokens that can be minted per epoch (100 million XOM)
    /// @dev Prevents runaway minting from a compromised MINTER_ROLE key.
    ///      Block rewards at ~15.6 XOM/block with 2s blocks = ~28,080 XOM/hour.
    ///      100M per hour gives generous headroom for bonuses and legitimate minting.
    uint256 public constant MAX_MINT_PER_EPOCH = 100_000_000e18;

    // ──────────────────────────────────────────────────────────────────────
    // Immutable state
    // ──────────────────────────────────────────────────────────────────────

    /// @notice The OmniCoin token contract (typed for compile-time mint() safety)
    IOmniCoinMintable public immutable TOKEN;

    // ──────────────────────────────────────────────────────────────────────
    // Rate limiting state (M-03)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Current epoch number (block.timestamp / EPOCH_DURATION)
    uint256 public currentEpoch;

    /// @notice Amount minted in the current epoch
    uint256 public epochMinted;

    // ──────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Emitted when tokens are minted through the controller
    /// @param to Recipient address
    /// @param amount Amount minted (in wei)
    /// @param newTotalSupply Total supply after minting
    event ControlledMint(
        address indexed to,
        uint256 indexed amount,
        uint256 indexed newTotalSupply
    );

    // ──────────────────────────────────────────────────────────────────────
    // Custom errors
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Thrown when a mint would exceed MAX_SUPPLY
    /// @param requested The amount requested to mint
    /// @param remaining The remaining mintable supply
    error MaxSupplyExceeded(uint256 requested, uint256 remaining);

    /// @notice Thrown when mint amount is zero
    error ZeroAmount();

    /// @notice Thrown when recipient address is the zero address
    error InvalidAddress();

    /// @notice Thrown when post-mint total supply exceeds MAX_SUPPLY (TOCTOU guard)
    /// @param postMintSupply The actual supply after minting
    /// @param maxSupply The immutable supply cap
    error SupplyCapViolated(uint256 postMintSupply, uint256 maxSupply);

    /// @notice Thrown when minting would exceed per-epoch rate limit
    /// @param requested Amount requested to mint
    /// @param remainingInEpoch Remaining mintable amount in this epoch
    error EpochRateLimitExceeded(uint256 requested, uint256 remainingInEpoch);

    // ──────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Deploy the MintController
     * @param token_ The OmniCoin token contract address
     * @dev Grants DEFAULT_ADMIN_ROLE and MINTER_ROLE to the deployer.
     *      The deployer should transfer admin to the TimelockController
     *      and grant MINTER_ROLE to authorized minting services
     *      (e.g., BlockRewardService, BonusService) before revoking
     *      their own roles.
     */
    constructor(address token_) {
        if (token_ == address(0)) revert InvalidAddress();

        TOKEN = IOmniCoinMintable(token_);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    // ──────────────────────────────────────────────────────────────────────
    // External state-changing functions
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Mint new XOM tokens, enforcing the supply cap
     * @param to Recipient address
     * @param amount Amount to mint (in wei, 18 decimals)
     * @dev Reverts if:
     *   - Caller lacks MINTER_ROLE
     *   - amount is zero
     *   - to is address(0)
     *   - Pre-mint check: totalSupply() + amount > MAX_SUPPLY
     *   - Post-mint assertion: totalSupply() > MAX_SUPPLY (TOCTOU guard)
     *
     *   The post-mint assertion eliminates the TOCTOU race condition where
     *   concurrent minters could collectively exceed MAX_SUPPLY by reading
     *   the same pre-mint totalSupply() value.
     */
    function mint(
        address to,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert InvalidAddress();

        // M-03: Per-epoch rate limiting
        // solhint-disable-next-line not-rely-on-time
        uint256 epoch = block.timestamp / EPOCH_DURATION;
        if (epoch != currentEpoch) {
            currentEpoch = epoch;
            epochMinted = 0;
        }
        if (epochMinted + amount > MAX_MINT_PER_EPOCH) {
            revert EpochRateLimitExceeded(amount, MAX_MINT_PER_EPOCH - epochMinted);
        }
        epochMinted += amount;

        // Pre-mint supply check (fast fail for obvious overflows)
        uint256 preMintSupply = TOKEN.totalSupply();
        uint256 remaining = MAX_SUPPLY > preMintSupply
            ? MAX_SUPPLY - preMintSupply
            : 0;

        if (amount > remaining) {
            revert MaxSupplyExceeded(amount, remaining);
        }

        // Execute mint via typed interface (compile-time signature verification)
        TOKEN.mint(to, amount);

        // Post-mint assertion: verify actual supply did not exceed cap.
        // This eliminates the TOCTOU race condition where concurrent minters
        // could each pass the pre-mint check with the same stale supply value.
        uint256 postMintSupply = TOKEN.totalSupply();
        if (postMintSupply > MAX_SUPPLY) {
            revert SupplyCapViolated(postMintSupply, MAX_SUPPLY);
        }

        emit ControlledMint(to, amount, postMintSupply);
    }

    /**
     * @notice Pause minting operations
     * @dev Only callable by addresses with PAUSER_ROLE. Use in emergencies
     *      to halt all minting while investigating a security incident.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause minting operations
     * @dev Only callable by addresses with PAUSER_ROLE
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ──────────────────────────────────────────────────────────────────────
    // External view functions
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Get the remaining mintable supply
     * @return The number of tokens that can still be minted before hitting the cap
     */
    function remainingMintable() external view returns (uint256) {
        uint256 supply = TOKEN.totalSupply();
        // solhint-disable-next-line gas-strict-inequalities
        if (supply >= MAX_SUPPLY) {
            return 0;
        }
        return MAX_SUPPLY - supply;
    }

    /**
     * @notice Get the current total supply of the token
     * @return The current totalSupply from the OmniCoin contract
     */
    function currentSupply() external view returns (uint256) {
        return TOKEN.totalSupply();
    }

    /**
     * @notice Get the remaining mintable amount in the current epoch
     * @return remainingInEpoch Tokens that can still be minted this epoch
     */
    function remainingInCurrentEpoch() external view returns (uint256 remainingInEpoch) {
        // solhint-disable-next-line not-rely-on-time
        uint256 epoch = block.timestamp / EPOCH_DURATION;
        if (epoch != currentEpoch) {
            return MAX_MINT_PER_EPOCH;
        }
        return MAX_MINT_PER_EPOCH > epochMinted ? MAX_MINT_PER_EPOCH - epochMinted : 0;
    }

    // ──────────────────────────────────────────────────────────────────────
    // External pure functions
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Get the maximum supply cap
     * @return The MAX_SUPPLY constant (16.6 billion XOM in wei)
     */
    function maxSupplyCap() external pure returns (uint256) {
        return MAX_SUPPLY;
    }
}
