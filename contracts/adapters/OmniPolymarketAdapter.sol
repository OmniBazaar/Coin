// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RouterAdapterBase} from "./RouterAdapterBase.sol";

/**
 * @title OmniPolymarketAdapter
 * @author Omni Development DAO
 * @notice Tier-B funding-step wrapper for Polymarket on Polygon.
 *
 *         Polymarket's CTF Exchange v2 (live since 2026-04-28) gates
 *         on-chain order execution behind an `onlyOperator` modifier —
 *         only Polymarket's controlled operator can submit fills.
 *         Third-party adapters cannot insert themselves into the
 *         trade-execution path. The economics this adapter captures is
 *         therefore the FUNDING step: USDC routed from a user's wallet
 *         (embedded or external) to the user's per-account Polymarket
 *         deposit address (a deterministic Polymarket Proxy smart-wallet
 *         derived from their Magic-MPC email account).
 *
 *         Flow:
 *           1. User chooses "Fund Polymarket" in OmniBazaar UI.
 *           2. UI passes the user's known Polymarket deposit address.
 *           3. User calls `fundDeposit(netUsdcAmount, depositAddr)`.
 *           4. Adapter pulls `gross = net * 1.0025` USDC from msg.sender.
 *           5. Adapter skims fee to UnifiedFeeVault (Polygon).
 *           6. Adapter forwards net USDC to the deposit address.
 *           7. Polymarket's Collateral Onramp wraps USDC into pUSD
 *              off-chain. User trades on Polymarket's own surface.
 *
 *         External-wallet users (MetaMask, Coinbase Wallet, hardware
 *         Safes) work identically — `msg.sender` is whichever wallet
 *         signs the tx. Revenue capture depends on the user CHOOSING
 *         to route through this adapter; competitive value-add (gasless
 *         via OmniRelay, deep-link, cross-chain bridge combined,
 *         remembered deposit address) drives that choice. See
 *         `the internal revenue-tier plan` Phase 1 addendum 2.
 *
 * @dev Decision: `decision_revenue_architecture_2026-05-27.md`.
 *      Detailed design: `the internal revenue-tier plan`.
 */
contract OmniPolymarketAdapter is RouterAdapterBase {
    using SafeERC20 for IERC20;

    /// @notice Emitted on every successful funding tx for off-chain
    ///         indexing + per-user lifetime-revenue analytics.
    /// @param user        Address that signed the tx
    /// @param depositAddr Polymarket Proxy deposit address that received the net USDC
    /// @param grossUsdc   Total USDC pulled from `user`
    /// @param feeUsdc     Fee portion sent to {FEE_VAULT}
    /// @param netUsdc     Net USDC delivered to `depositAddr`
    event PolymarketFunded(
        address indexed user,
        address indexed depositAddr,
        uint256 indexed grossUsdc,
        uint256 feeUsdc,
        uint256 netUsdc
    );

    /// @dev Reverts when the destination deposit address is zero.
    error InvalidDepositAddress();

    /**
     * @notice Deploy the Polymarket funding-step adapter with a fixed
     *         25 bp protocol fee.
     * @param usdc      Polygon USDC (native or USDC.e — caller picks at
     *                  deploy time; only ONE input token per adapter
     *                  instance).
     * @param feeVault  UnifiedFeeVault address on Polygon (or a bridged
     *                  fee-collector that forwards to the L1 vault).
     */
    constructor(address usdc, address feeVault)
        RouterAdapterBase(usdc, feeVault, 25)
    {}

    /**
     * @notice Fund a Polymarket deposit address with a 25 bp routing fee.
     * @dev Caller must approve `quoteGrossForNet(netUsdcAmount)` of
     *      {INPUT_TOKEN} to this adapter before calling. The adapter
     *      makes two transfers: fee to {FEE_VAULT}, net to
     *      `polymarketDepositAddr`. No state is kept across txs.
     * @param netUsdcAmount         USDC the user wants delivered to
     *                              Polymarket (post-fee).
     * @param polymarketDepositAddr User's Polymarket Proxy address on
     *                              Polygon. UI must obtain this from the
     *                              user's Polymarket account (deterministic
     *                              per Magic-MPC email).
     */
    function fundDeposit(uint256 netUsdcAmount, address polymarketDepositAddr) external nonReentrant {
        if (polymarketDepositAddr == address(0)) revert InvalidDepositAddress();

        (uint256 feeUsdc, uint256 grossUsdc) = _collectGrossAndForwardFee(netUsdcAmount);

        INPUT_TOKEN.safeTransfer(polymarketDepositAddr, netUsdcAmount);

        emit PolymarketFunded(
            msg.sender,
            polymarketDepositAddr,
            grossUsdc,
            feeUsdc,
            netUsdcAmount
        );
    }
}
