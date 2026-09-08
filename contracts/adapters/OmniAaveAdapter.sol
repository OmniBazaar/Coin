// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RouterAdapterBase} from "./RouterAdapterBase.sol";

/**
 * @title IAaveV3Pool
 * @author Omni Development DAO
 * @notice Minimal interface for Aave V3's unified `Pool` contract.
 * @dev Verified against Aave V3 production deployment on Ethereum mainnet
 *      at `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2`. The `supply`
 *      function is permissionless and accepts `onBehalfOf` to mint aTokens
 *      to an arbitrary recipient — exactly what an adapter needs.
 */
interface IAaveV3Pool {
    /**
     * @notice Supply `amount` of `asset` to the protocol, minting the
     *         corresponding aToken to `onBehalfOf`.
     * @param asset Address of the reserve asset (e.g. USDC).
     * @param amount Amount of `asset` to deposit.
     * @param onBehalfOf Address that receives the minted aTokens.
     * @param referralCode Aave's referral / integrator code (set to our
     *                    registered code so Aave can track integrator
     *                    activity; non-zero values are recorded in Aave's
     *                    SupplyLogic.executeSupply event for off-chain
     *                    revenue-share programs).
     */
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;
}

/**
 * @title OmniAaveAdapter
 * @author Omni Development DAO
 * @notice Tier-B supply wrapper for Aave V3 (chosen 2026-05-27 as the
 *         second RWA archetype after Ondo OUSG was blocked by v1
 *         deprecation + v2 attestation-requirement; see
 *         `the internal revenue-tier plan` Phase 2.5 results).
 *
 *         Distinct archetype from {OmniSdaiAdapter} (ERC-4626 standardized
 *         vault) — Aave uses a protocol-specific `Pool.supply` API with
 *         an `onBehalfOf` recipient parameter. Proving the adapter pattern
 *         across both standardized and protocol-native shapes.
 *
 *         Flow:
 *           1. UI shows: "Supply 1,000 USDC to Aave (current rate ~4.5%)"
 *           2. User signs `supplyAave(netUsdcAmount)`.
 *           3. Adapter pulls `gross = net * 1.0025` USDC from msg.sender.
 *           4. Adapter skims fee to UnifiedFeeVault.
 *           5. Adapter approves Aave Pool for net USDC.
 *           6. Adapter calls `pool.supply(USDC, net, msg.sender, REFERRAL_CODE)`.
 *           7. Aave mints aUSDC directly to user. aUSDC is freely
 *              transferable, earns interest by balance accrual.
 *
 *         Notable upside: Aave's `referralCode` is a built-in affiliate
 *         hook. If we register an integrator code with Aave's governance
 *         (post-launch), we earn Tier C revenue ON TOP of our 25 bp Tier B
 *         skim — no extra contract logic. For now we ship with code = 0
 *         (no affiliate side-channel) and can upgrade later.
 *
 *         External wallets (MetaMask, hardware) work identically — adapter
 *         only cares about `msg.sender` having approved USDC. Aave's
 *         `onBehalfOf` is set to `msg.sender` so aUSDC lands in whichever
 *         wallet signed the tx.
 *
 * @dev Decision: `decision_revenue_architecture_2026-05-27.md`.
 *      Plan: `the internal revenue-tier plan` Phase 2.7 (Aave substitution
 *      for Ondo OUSG, founder-approved 2026-05-27).
 */
contract OmniAaveAdapter is RouterAdapterBase {
    using SafeERC20 for IERC20;

    /// @notice Aave V3 unified Pool contract on this adapter's home chain.
    ///         Ethereum mainnet: `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2`.
    address public immutable POOL;
    /// @notice The aToken address for the supplied asset (e.g., aEthUSDC).
    ///         Used for event-emit accounting; the adapter never holds it.
    address public immutable A_TOKEN;
    /// @notice Aave integrator referral code. Zero by default; can be
    ///         updated post-launch by redeploying with a registered code.
    uint16 public immutable REFERRAL_CODE;

    /// @notice Emitted on every successful Aave supply.
    /// @param user            Address that signed the tx + receives aTokens
    /// @param grossAssets     Total input asset pulled from `user`
    /// @param aTokensReceived aTokens delivered to `user` (≈ netAssets)
    /// @param feeAssets       Fee portion sent to {FEE_VAULT}
    /// @param netAssets       Net assets supplied to Aave's pool
    event AaveSupplied(
        address indexed user,
        uint256 indexed grossAssets,
        uint256 indexed aTokensReceived,
        uint256 feeAssets,
        uint256 netAssets
    );

    /// @dev Reverts if Aave's `supply` somehow returns zero aTokens to
    ///      the user (anomalous; protects against silent failure).
    error SupplyReturnedZeroATokens();

    /// @notice Aave delivered fewer aTokens than the caller's floor (M-07).
    /// @param received aTokens actually delivered.
    /// @param minATokensOut Caller's signed minimum.
    error SlippageExceeded(uint256 received, uint256 minATokensOut);

    /**
     * @notice Deploy the Aave supply adapter with a fixed 25 bp protocol fee.
     * @param asset      Underlying asset (e.g., USDC on Ethereum).
     * @param feeVault   UnifiedFeeVault on this adapter's home chain.
     * @param pool       Aave V3 unified Pool contract.
     * @param aToken     aToken for the supplied asset (e.g., aEthUSDC).
     * @param referralCode Aave integrator code. Use 0 until we have a
     *                     governance-registered code from Aave.
     */
    constructor(
        address asset,
        address feeVault,
        address pool,
        address aToken,
        uint16 referralCode
    ) RouterAdapterBase(asset, feeVault, 25) {
        if (pool == address(0)) revert ZeroAddress("pool");
        if (aToken == address(0)) revert ZeroAddress("aToken");
        POOL = pool;
        A_TOKEN = aToken;
        REFERRAL_CODE = referralCode;
    }

    /**
     * @notice Supply `netAssetAmount` of the underlying to Aave V3 on
     *         behalf of `msg.sender` with a 25 bp routing fee.
     * @dev Caller must approve `quoteGrossForNet(netAssetAmount)` of
     *      {INPUT_TOKEN} to this adapter before calling. Aave mints
     *      aTokens directly to msg.sender; no adapter-held intermediate
     *      state. aTokens earn interest by balance accrual.
     * @param netAssetAmount Net assets to supply to Aave (post-fee).
     * @param minATokensOut Minimum aTokens the caller will accept (M-07
     *        slippage floor). aTokens are ≈1:1 with the supplied asset,
     *        but bounding the delta defends the generic path against a
     *        manipulated aToken accounting; pass `0` for no floor.
     * @return aTokensReceived aTokens minted to msg.sender (≈ netAssetAmount).
     */
    function supplyAave(uint256 netAssetAmount, uint256 minATokensOut)
        external
        nonReentrant
        returns (uint256 aTokensReceived)
    {
        (uint256 feeAssets, uint256 grossAssets) =
            _collectGrossAndForwardFee(netAssetAmount);

        // forceApprove handles any prior dangling approval state.
        INPUT_TOKEN.forceApprove(POOL, netAssetAmount);

        // Snapshot before so we can compute the exact aToken delta
        // (Aave's supply does not return a value).
        uint256 balBefore = IERC20(A_TOKEN).balanceOf(msg.sender);
        IAaveV3Pool(POOL).supply(
            address(INPUT_TOKEN),
            netAssetAmount,
            msg.sender,
            REFERRAL_CODE
        );
        uint256 balAfter = IERC20(A_TOKEN).balanceOf(msg.sender);

        aTokensReceived = balAfter - balBefore;
        if (aTokensReceived == 0) revert SupplyReturnedZeroATokens();
        // M-07: enforce the caller's slippage floor.
        if (aTokensReceived < minATokensOut) {
            revert SlippageExceeded(aTokensReceived, minATokensOut);
        }

        emit AaveSupplied(
            msg.sender,
            grossAssets,
            aTokensReceived,
            feeAssets,
            netAssetAmount
        );
    }
}
