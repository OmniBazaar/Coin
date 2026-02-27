// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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
 * @dev Wraps OmniCoin's mint() function with an immutable
 *      MAX_SUPPLY check and per-epoch rate limiting.
 *
 * Deployment model:
 *   1. Deploy MintController with the OmniCoin token address
 *   2. Grant MINTER_ROLE on OmniCoin to this MintController
 *   3. Revoke MINTER_ROLE from the deployer on OmniCoin
 *   4. All future minting flows through this contract
 *
 * The MAX_SUPPLY constant (16.6 billion XOM) matches published
 * tokenomics. Once totalSupply() reaches this cap, no further
 * minting is possible -- there is no admin override, upgrade
 * path, or emergency bypass.
 *
 * Emission Schedule:
 *   - Total supply: 16.6 billion XOM
 *   - Genesis supply: ~4.13 billion XOM
 *   - Planned emissions: ~12.47 billion XOM over 40 years
 *   - Block rewards: 6.089 billion XOM (40 years)
 *   - Welcome bonuses: 1.383 billion XOM
 *   - Referral bonuses: 2.995 billion XOM
 *   - First sale bonuses: 2.000 billion XOM
 *
 * Epoch Reduction Schedule (1% per epoch):
 *   - Epoch 0 (blocks 0-6,311,519): 15.602 XOM/block
 *   - Epoch 1 (blocks 6,311,520-12,623,039): 15.446 XOM/block
 *   - Epoch 2 (blocks 12,623,040-18,934,559): 15.291 XOM/block
 *   - ...
 *   - Epoch 50 (~year 20): ~9.46 XOM/block
 *   - Epoch 99 (~year 40): ~5.79 XOM/block
 *   - Epoch 100+: 0 XOM/block (emissions exhausted)
 *
 * Security:
 *   - AccessControlDefaultAdminRules: 2-step admin transfer
 *     with 48-hour delay (M-01 audit fix)
 *   - Per-epoch rate limit: 100M XOM/hour max
 *   - Post-mint TOCTOU assertion
 *   - Pausable with asymmetric unpause (M-02 audit fix)
 *   - ReentrancyGuard on mint()
 */
contract MintController is
    AccessControlDefaultAdminRules,
    Pausable,
    ReentrancyGuard
{
    // ──────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────

    /// @notice Role for addresses authorized to mint via this controller
    bytes32 public constant MINTER_ROLE =
        keccak256("MINTER_ROLE");

    /// @notice Role for addresses authorized to pause minting
    bytes32 public constant PAUSER_ROLE =
        keccak256("PAUSER_ROLE");

    /// @notice Maximum total supply of XOM tokens
    /// @dev 16.6 billion with 18 decimals. Immutable and
    ///      cannot be changed post-deployment.
    uint256 public constant MAX_SUPPLY = 16_600_000_000e18;

    /// @notice Duration of a rate-limiting epoch (1 hour)
    uint256 public constant EPOCH_DURATION = 1 hours;

    /// @notice Maximum tokens that can be minted per epoch
    /// @dev Prevents runaway minting from a compromised
    ///      MINTER_ROLE key. Block rewards at ~15.6 XOM/block
    ///      with 2s blocks = ~28,080 XOM/hour. 100M per hour
    ///      gives generous headroom for bonuses and legitimate
    ///      minting.
    uint256 public constant MAX_MINT_PER_EPOCH = 100_000_000e18;

    /// @notice Admin transfer delay for AccessControlDefaultAdminRules
    /// @dev 48 hours in seconds. Matches OmniCoin's admin delay.
    uint48 public constant ADMIN_TRANSFER_DELAY = 48 hours;

    // ──────────────────────────────────────────────────────────────
    // Immutable state
    // ──────────────────────────────────────────────────────────────

    /// @notice The OmniCoin token contract
    /// @dev Typed for compile-time mint() signature safety.
    ///      Immutable: cannot be changed post-deployment.
    IOmniCoinMintable public immutable TOKEN;

    // ──────────────────────────────────────────────────────────────
    // Rate limiting state
    // ──────────────────────────────────────────────────────────────

    /// @notice Current epoch number (block.timestamp / EPOCH_DURATION)
    /// @dev May be stale if no mint() called this epoch. Use
    ///      currentEpochInfo() for accurate data.
    uint256 public currentEpoch;

    /// @notice Amount minted in the current epoch
    /// @dev May be stale if no mint() called this epoch. Use
    ///      currentEpochInfo() or remainingInCurrentEpoch()
    ///      for accurate data.
    uint256 public epochMinted;

    // ──────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────

    /* solhint-disable gas-indexed-events */
    /// @notice Emitted when tokens are minted through the controller
    /// @param to Recipient address
    /// @param amount Amount minted (in wei, NOT indexed per L-01
    ///        audit fix: indexed uint256 stores keccak256(value),
    ///        losing the raw value from event data, which breaks
    ///        off-chain indexer parsing)
    /// @param newTotalSupply Total supply after minting (NOT indexed
    ///        for the same reason as amount)
    event ControlledMint(
        address indexed to,
        uint256 amount,
        uint256 newTotalSupply
    );
    /* solhint-enable gas-indexed-events */

    // ──────────────────────────────────────────────────────────────
    // Custom errors
    // ──────────────────────────────────────────────────────────────

    /// @notice Thrown when a mint would exceed MAX_SUPPLY
    /// @param requested The amount requested to mint
    /// @param remaining The remaining mintable supply
    error MaxSupplyExceeded(
        uint256 requested,
        uint256 remaining
    );

    /// @notice Thrown when mint amount is zero
    error ZeroAmount();

    /// @notice Thrown when recipient address is the zero address
    error InvalidAddress();

    /// @notice Thrown when post-mint total supply exceeds MAX_SUPPLY
    /// @dev TOCTOU guard: catches concurrent minters that each
    ///      pass the pre-mint check with the same stale supply.
    /// @param postMintSupply The actual supply after minting
    /// @param maxSupply The immutable supply cap
    error SupplyCapViolated(
        uint256 postMintSupply,
        uint256 maxSupply
    );

    /// @notice Thrown when minting would exceed per-epoch rate limit
    /// @param requested Amount requested to mint
    /// @param remainingInEpoch Remaining mintable in this epoch
    error EpochRateLimitExceeded(
        uint256 requested,
        uint256 remainingInEpoch
    );

    // ──────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Deploy the MintController
     * @param token_ The OmniCoin token contract address
     * @dev Grants DEFAULT_ADMIN_ROLE, MINTER_ROLE, and PAUSER_ROLE
     *      to the deployer. Uses AccessControlDefaultAdminRules with
     *      a 48-hour admin transfer delay (M-01 audit fix).
     *
     *      The deployer should:
     *        1. Grant MINTER_ROLE to authorized services
     *           (BlockRewardService, BonusService)
     *        2. Grant PAUSER_ROLE to EmergencyGuardian
     *        3. Transfer admin to OmniTimelockController
     *        4. Revoke own MINTER_ROLE and PAUSER_ROLE
     */
    constructor(
        address token_
    )
        AccessControlDefaultAdminRules(
            ADMIN_TRANSFER_DELAY, msg.sender
        )
    {
        if (token_ == address(0)) revert InvalidAddress();

        TOKEN = IOmniCoinMintable(token_);

        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    // ──────────────────────────────────────────────────────────────
    // External state-changing functions
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Mint new XOM tokens, enforcing the supply cap
     * @param to Recipient address
     * @param amount Amount to mint (in wei, 18 decimals)
     * @dev Reverts if:
     *   - Caller lacks MINTER_ROLE
     *   - Contract is paused
     *   - amount is zero
     *   - to is address(0)
     *   - Per-epoch rate limit exceeded
     *   - Pre-mint check: totalSupply() + amount > MAX_SUPPLY
     *   - Post-mint assertion: totalSupply() > MAX_SUPPLY
     *
     *   The post-mint assertion eliminates the TOCTOU race
     *   condition where concurrent minters could collectively
     *   exceed MAX_SUPPLY by reading the same pre-mint
     *   totalSupply() value.
     */
    function mint(
        address to,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert InvalidAddress();

        // Per-epoch rate limiting
        // solhint-disable-next-line not-rely-on-time
        uint256 epoch = block.timestamp / EPOCH_DURATION;
        if (epoch != currentEpoch) {
            currentEpoch = epoch;
            epochMinted = 0;
        }
        if (epochMinted + amount > MAX_MINT_PER_EPOCH) {
            revert EpochRateLimitExceeded(
                amount, MAX_MINT_PER_EPOCH - epochMinted
            );
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

        // Execute mint via typed interface
        TOKEN.mint(to, amount);

        // Post-mint assertion: verify actual supply did not
        // exceed cap. Eliminates the TOCTOU race condition.
        uint256 postMintSupply = TOKEN.totalSupply();
        if (postMintSupply > MAX_SUPPLY) {
            revert SupplyCapViolated(
                postMintSupply, MAX_SUPPLY
            );
        }

        emit ControlledMint(to, amount, postMintSupply);
    }

    /**
     * @notice Pause minting operations
     * @dev Only callable by PAUSER_ROLE. Use in emergencies
     *      to halt all minting while investigating a security
     *      incident. Pausing is a fast emergency action that
     *      can be done by a hot wallet.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause minting operations
     * @dev M-02 audit fix: restricted to DEFAULT_ADMIN_ROLE only.
     *      Unpausing is a deliberate governance action requiring
     *      the timelock/multisig, ensuring the emergency pause
     *      is only lifted after proper investigation. This
     *      prevents a compromised PAUSER_ROLE from undoing a
     *      legitimate emergency pause.
     */
    function unpause()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _unpause();
    }

    // ──────────────────────────────────────────────────────────────
    // External view functions
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Get the remaining mintable supply
     * @return The number of tokens that can still be minted
     *         before hitting the cap
     */
    function remainingMintable()
        external
        view
        returns (uint256)
    {
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
    function currentSupply()
        external
        view
        returns (uint256)
    {
        return TOKEN.totalSupply();
    }

    /**
     * @notice Get the remaining mintable amount in the current epoch
     * @return remainingInEpoch Tokens that can still be minted
     *         this epoch (resets every EPOCH_DURATION)
     */
    function remainingInCurrentEpoch()
        external
        view
        returns (uint256 remainingInEpoch)
    {
        // solhint-disable-next-line not-rely-on-time
        uint256 epoch = block.timestamp / EPOCH_DURATION;
        if (epoch != currentEpoch) {
            return MAX_MINT_PER_EPOCH;
        }
        return MAX_MINT_PER_EPOCH > epochMinted
            ? MAX_MINT_PER_EPOCH - epochMinted
            : 0;
    }

    /**
     * @notice Get comprehensive current epoch information
     * @dev M-03 audit fix: returns accurate epoch data even
     *      when the stored currentEpoch/epochMinted are stale
     *      (no mint() call in the current epoch). Prevents
     *      off-chain integration errors from reading stale
     *      raw storage variables.
     * @return epoch The actual current epoch number
     * @return minted Amount minted so far in this epoch
     * @return remaining Amount that can still be minted this epoch
     * @return reward Current block reward for this epoch
     *         (based on emission schedule)
     * @return blocksInEpoch Number of blocks remaining in the
     *         current reduction period (approximate)
     * @return totalMinted Total supply minted to date
     */
    function currentEpochInfo()
        external
        view
        returns (
            uint256 epoch,
            uint256 minted,
            uint256 remaining,
            uint256 reward,
            uint256 blocksInEpoch,
            uint256 totalMinted
        )
    {
        // solhint-disable-next-line not-rely-on-time
        epoch = block.timestamp / EPOCH_DURATION;

        if (epoch == currentEpoch) {
            minted = epochMinted;
            remaining = MAX_MINT_PER_EPOCH > epochMinted
                ? MAX_MINT_PER_EPOCH - epochMinted
                : 0;
        } else {
            minted = 0;
            remaining = MAX_MINT_PER_EPOCH;
        }

        totalMinted = TOKEN.totalSupply();

        // Approximate block reward (not stored here but useful)
        // Initial: 15.602 XOM, reduced 1% per 6,311,520 blocks
        reward = _approximateBlockReward(epoch);

        // Blocks remaining in current reduction period
        uint256 reductionPeriod = 6_311_520;
        uint256 epochBlock = epoch; // 1 epoch = 1 block (2s)
        blocksInEpoch = reductionPeriod
            - (epochBlock % reductionPeriod);
    }

    // ──────────────────────────────────────────────────────────────
    // External pure functions
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Get the maximum supply cap
     * @return The MAX_SUPPLY constant (16.6 billion XOM in wei)
     */
    function maxSupplyCap()
        external
        pure
        returns (uint256)
    {
        return MAX_SUPPLY;
    }

    // ──────────────────────────────────────────────────────────────
    // Internal functions
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Approximate block reward for a given epoch
     * @param epoch The epoch/block number
     * @return reward Approximate block reward in XOM (18 decimals)
     * @dev Mirrors the OmniValidatorRewards calculation:
     *      Initial 15.602 XOM, reduced 1% every 6,311,520 epochs.
     *      After 100 reduction periods, reward is 0.
     */
    function _approximateBlockReward(
        uint256 epoch
    ) internal pure returns (uint256 reward) {
        uint256 reductions = epoch / 6_311_520;
        if (reductions > 99) {
            return 0;
        }

        reward = 15_602_000_000_000_000_000; // 15.602 XOM

        for (uint256 i = 0; i < reductions;) {
            reward = (reward * 99) / 100;
            unchecked { ++i; }
        }
    }
}
