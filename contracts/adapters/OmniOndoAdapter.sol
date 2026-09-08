// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ════════════════════════════════════════════════════════════════════════════
// 🛑 DEPRECATED — DO NOT DEPLOY, DO NOT REWRITE, DO NOT RE-LITIGATE.
//
// This contract targets Ondo's v1 OUSGInstantManager ABI (`mint(uint256)`),
// which Ondo retired on 2025-04-07. The live v2 Instant Manager uses an
// attestation-based `mintWithAttestation` flow that this source does not
// implement. Deploying it as-is would produce a broken mint.
//
// Ondo access is already served through the RWA aggregator link-out
// (the Ondo Finance modern API — OUSG/USDY/rOUSG/MMF).
// Native custody-in-wallet OUSG minting, if ever wanted, is a FUTURE v2
// rewrite (attestation-aware), NOT a deploy of this file. Founder ruling
// 2026-08-20: closed as "Ondo served via aggregator; native mint = future v2
// rewrite". Kept only as historical reference for that future rewrite.
// ════════════════════════════════════════════════════════════════════════════

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RouterAdapterBase} from "../adapters/RouterAdapterBase.sol";

/**
 * @title IOusgInstantManager
 * @author Omni Development DAO
 * @notice Minimal interface for Ondo's OUSGInstantManager.
 * @dev Verified against the 2024-03 Code4rena audit source. The `mint`
 *      function is `external`, has no caller allowlist, and returns the
 *      OUSG amount that was minted to `msg.sender` (the adapter). Per-tx
 *      caps + global daily caps are enforced internally by Ondo's
 *      rate limiter; if exceeded, `mint` reverts.
 */
interface IOusgInstantManager {
    /// @notice Mint OUSG against `usdcAmountIn` USDC. OUSG goes to msg.sender.
    /// @param usdcAmountIn USDC amount to convert. Adapter must hold this
    ///                     balance and have approved {OUSG_MANAGER} first.
    /// @return ousgAmountOut OUSG minted to caller (this adapter).
    function mint(uint256 usdcAmountIn) external returns (uint256 ousgAmountOut);
}

/**
 * @title OmniOndoAdapter
 * @author Omni Development DAO
 * @notice Tier-B mint wrapper for Ondo Finance OUSG on Ethereum.
 *
 *         Flow:
 *           1. UI pre-checks the user is Ondo-allowlisted (off-chain
 *              via Ondo's allowlist view). Unverified users see a
 *              "Complete Ondo KYC first" link-out and never reach this
 *              contract.
 *           2. User calls `mintOusg(netUsdcAmount)`.
 *           3. Adapter pulls `gross = net * 1.0025` USDC from msg.sender.
 *           4. Adapter skims fee to UnifiedFeeVault.
 *           5. Adapter approves {OUSG_MANAGER} for net USDC + calls
 *              `mint(net)` — OUSG mints to the adapter.
 *           6. Adapter transfers OUSG to msg.sender. Reverts atomically
 *              if OUSG's transfer-restriction blocks the adapter as
 *              sender. (Phase 2 fork test verifies whether this works;
 *              if not, fallback per `the internal revenue-tier plan`
 *              Phase 1.2: BD outreach to Ondo for adapter allowlisting,
 *              OR pivot to Backed Finance bTokens, OR USDC-deposit-router
 *              with off-chain settlement.)
 *
 *         Production constraints on the Ondo side (informational):
 *         - $5,000 minimum mint enforced by OUSGInstantManager.
 *         - $25M per-investor / $50M global 24h cap.
 *         - 0% mint fee on the Ondo side; 0.15% annual management fee.
 *         - OUSG is a "qualified-access" token; transfer restrictions
 *           apply.
 *
 *         External-wallet users work identically — adapter only cares
 *         about `msg.sender` having approved USDC and being on Ondo's
 *         allowlist.
 *
 * @dev Decision: `decision_revenue_architecture_2026-05-27.md`.
 *      Detailed design + fallback ladder if step 6 reverts:
 *      `the internal revenue-tier plan`.
 */
contract OmniOndoAdapter is RouterAdapterBase {
    using SafeERC20 for IERC20;

    /// @notice Ondo's OUSGInstantManager (Ethereum mainnet
    ///         `0x2826989983e3a66f0622132d019c2ae173eb6a43` at audit time;
    ///         pass at deploy so we can re-target to "Instant Manager 2"
    ///         or future versions without redeploying the adapter).
    address public immutable OUSG_MANAGER;
    /// @notice Ondo's OUSG ERC-20 token contract.
    address public immutable OUSG;

    /// @notice Emitted on every successful mint.
    /// @param user      Address that signed the tx + receives the OUSG
    /// @param grossUsdc Total USDC pulled from `user`
    /// @param ousgOut   OUSG minted + transferred to `user`
    /// @param feeUsdc   Fee portion sent to {FEE_VAULT}
    /// @param netUsdc   Net USDC sent to Ondo for minting
    event OndoMinted(
        address indexed user,
        uint256 indexed grossUsdc,
        uint256 indexed ousgOut,
        uint256 feeUsdc,
        uint256 netUsdc
    );

    /// @dev Reverts if Ondo's `mint` call returns zero (anomalous but
    ///      possible under depeg + slippage scenarios). Pre-empts the
    ///      adapter holding a stuck zero OUSG balance.
    error MintReturnedZero();

    /// @notice Ondo minted less OUSG than the caller's floor (M-07).
    /// @param received OUSG actually minted.
    /// @param minOusgOut Caller's signed minimum.
    error SlippageExceeded(uint256 received, uint256 minOusgOut);

    /**
     * @notice Deploy the Ondo OUSG mint adapter with a fixed 25 bp
     *         protocol fee.
     * @param usdc        Ethereum USDC (`0xa0b86991...` canonical).
     * @param feeVault    UnifiedFeeVault on Ethereum (or bridged
     *                    fee-collector that forwards to L1 vault).
     * @param ousgManager Ondo OUSGInstantManager address.
     * @param ousg        Ondo OUSG ERC-20 address.
     */
    constructor(
        address usdc,
        address feeVault,
        address ousgManager,
        address ousg
    ) RouterAdapterBase(usdc, feeVault, 25) {
        if (ousgManager == address(0)) revert ZeroAddress("ousgManager");
        if (ousg == address(0)) revert ZeroAddress("ousg");
        OUSG_MANAGER = ousgManager;
        OUSG = ousg;
    }

    /**
     * @notice Mint OUSG to `msg.sender` via Ondo's Instant Manager.
     * @dev Caller must (a) be on Ondo's OUSG allowlist (verify
     *      off-chain before calling) and (b) have approved
     *      `quoteGrossForNet(netUsdcAmount)` of {INPUT_TOKEN} to this
     *      adapter. Reverts atomically if Ondo's per-tx min ($5K) is
     *      not met, if rate limits are exceeded, or if OUSG's transfer
     *      to `msg.sender` is rejected by its access-control logic.
     * @param netUsdcAmount Net USDC to send to Ondo for minting.
     * @param minOusgOut Minimum OUSG the caller will accept (M-07
     *        slippage floor) — bounds the USDC→OUSG price the caller
     *        signed against front-running of the instant-manager rate;
     *        pass `0` for an explicit no-floor call.
     * @return ousgAmountOut OUSG minted + transferred to `msg.sender`.
     */
    function mintOusg(uint256 netUsdcAmount, uint256 minOusgOut)
        external
        nonReentrant
        returns (uint256 ousgAmountOut)
    {
        (uint256 feeUsdc, uint256 grossUsdc) = _collectGrossAndForwardFee(netUsdcAmount);

        // forceApprove handles the case where a prior partial approval is
        // still outstanding (some USDC variants block setApproval from
        // non-zero to non-zero without going to zero first).
        INPUT_TOKEN.forceApprove(OUSG_MANAGER, netUsdcAmount);
        ousgAmountOut = IOusgInstantManager(OUSG_MANAGER).mint(netUsdcAmount);
        if (ousgAmountOut == 0) revert MintReturnedZero();
        // M-07: enforce the caller's slippage floor.
        if (ousgAmountOut < minOusgOut) {
            revert SlippageExceeded(ousgAmountOut, minOusgOut);
        }

        // Forward OUSG to user. Reverts atomically if Ondo's transfer-
        // restriction blocks the adapter as sender; Phase 2 fork test
        // verifies this works in practice.
        IERC20(OUSG).safeTransfer(msg.sender, ousgAmountOut);

        emit OndoMinted(msg.sender, grossUsdc, ousgAmountOut, feeUsdc, netUsdcAmount);
    }
}
