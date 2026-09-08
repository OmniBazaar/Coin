// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RouterAdapterBase
 * @author Omni Development DAO
 * @notice Common skeleton for Tier-B partner-protocol adapters that route
 *         user funds through OmniBazaar with a fixed-bps protocol fee
 *         skimmed atomically into UnifiedFeeVault.
 *
 *         Pattern (per `decision_revenue_architecture_2026-05-27.md`):
 *         user signs ONE tx that calls the partner-specific adapter with
 *         their input token. The adapter pulls input, transfers the fee
 *         portion to {FEE_VAULT}, forwards the remainder to the partner
 *         contract or destination address. Output token (if any) returns
 *         to the user atomically in the same tx.
 *
 *         Non-custodial: adapter never holds user balances across
 *         transactions. If any step reverts, the whole tx reverts and the
 *         user retains their input. Identical guarantee to Uniswap router
 *         / 1inch executor / Li.Fi diamond.
 *
 *         External wallets (MetaMask, Coinbase Wallet, hardware-wallet
 *         Safes) work identically to OmniBazaar embedded wallets — the
 *         adapter only cares about `msg.sender` having approved the input
 *         token and signed the tx.
 *
 * @dev Inherited by `OmniPolymarketAdapter`, `OmniOndoAdapter`, and
 *      future per-partner wrappers. Each subclass defines its own
 *      partner-specific entrypoint (e.g. `fundDeposit`, `mintOusg`) and
 *      calls {_collectGrossAndForwardFee} as the first step.
 */
abstract contract RouterAdapterBase is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Denominator for basis-point math.
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Input token the adapter accepts (USDC on the relevant chain).
    IERC20 public immutable INPUT_TOKEN;
    /// @notice Destination for the protocol fee portion (UnifiedFeeVault).
    address public immutable FEE_VAULT;
    /// @notice Protocol fee in basis points (1 bp = 0.01%). 25 = 0.25%.
    uint16 public immutable FEE_BPS;

    /// @dev Reverts when an input amount is zero.
    error ZeroAmount();
    /// @dev Reverts when a constructor address is the zero address.
    /// @param field Name of the field that received `address(0)`
    error ZeroAddress(string field);
    /// @dev Reverts when {FEE_BPS} is outside the [1, 500] sanity band.
    /// @param feeBps The disallowed configured value
    error FeeBpsOutOfBounds(uint16 feeBps);

    /**
     * @notice Construct a fee-routing adapter base. Subclasses pass the
     *         partner-specific input token + vault + fee bps to this.
     * @param inputToken Address of the ERC-20 input token (USDC on the
     *                   adapter's home chain).
     * @param feeVault   Address that receives the fee portion. Typically
     *                   the UnifiedFeeVault deployment for this chain.
     * @param feeBps     Protocol fee in basis points. Must be in [1, 500].
     */
    constructor(address inputToken, address feeVault, uint16 feeBps) {
        if (inputToken == address(0)) revert ZeroAddress("inputToken");
        if (feeVault == address(0)) revert ZeroAddress("feeVault");
        if (feeBps == 0 || feeBps > 500) revert FeeBpsOutOfBounds(feeBps);

        INPUT_TOKEN = IERC20(inputToken);
        FEE_VAULT = feeVault;
        FEE_BPS = feeBps;
    }

    /**
     * @notice Compute the gross input amount required to deliver
     *         `netAmount` after the fee is skimmed.
     * @dev Math: `gross = net * (BPS_DENOMINATOR + FEE_BPS) / BPS_DENOMINATOR`.
     *      For USDC (6 decimals) and typical sizes ($1+), rounding is
     *      sub-cent. For sub-dollar sizes the fee can floor to zero,
     *      which is acceptable — Polymarket and Ondo both enforce
     *      economic minimums on the receiving end.
     * @param netAmount Desired post-fee amount delivered to the partner.
     * @return grossAmount Total input the caller must approve.
     */
    function quoteGrossForNet(uint256 netAmount) public view returns (uint256 grossAmount) {
        grossAmount = (netAmount * (BPS_DENOMINATOR + FEE_BPS)) / BPS_DENOMINATOR;
    }

    /**
     * @notice Pull `grossAmount` of {INPUT_TOKEN} from `msg.sender`,
     *         forward the fee portion to {FEE_VAULT}, return the net
     *         portion that the subclass must forward to the partner.
     * @dev Subclass calls this as the first step of its partner-specific
     *      entrypoint. The net is returned in-memory; the subclass owns
     *      the next transfer (deposit-address send, partner-contract
     *      call, etc.).
     * @param netAmount Desired post-fee amount the subclass will forward.
     * @return feeAmount The fee portion transferred to {FEE_VAULT}.
     * @return grossAmount The total input pulled from `msg.sender`.
     */
    function _collectGrossAndForwardFee(uint256 netAmount)
        internal
        returns (uint256 feeAmount, uint256 grossAmount)
    {
        if (netAmount == 0) revert ZeroAmount();

        grossAmount = quoteGrossForNet(netAmount);
        feeAmount = grossAmount - netAmount;

        INPUT_TOKEN.safeTransferFrom(msg.sender, address(this), grossAmount);
        INPUT_TOKEN.safeTransfer(FEE_VAULT, feeAmount);
    }
}
