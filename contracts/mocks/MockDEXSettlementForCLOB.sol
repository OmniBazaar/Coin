// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockDEXSettlementForCLOB
 * @notice Minimal DEXSettlement stand-in for CLOBAdapter tests. Mirrors the
 *         `settleTrade(Order,Order,uint256,uint256,bytes,bytes)` selector the
 *         adapter calls via low-level `.call`, and moves tokens the way the
 *         real settlement does: pull the taker's tokenIn from the adapter,
 *         and pay the maker's tokenIn to the adapter.
 * @dev Test-only. Does not verify signatures — it exists to exercise the
 *      adapter's partial-fill bookkeeping (remainingIn/remainingOut) which is
 *      the root cause of the D-01 signature-poisoning bug.
 */
contract MockDEXSettlementForCLOB {
    struct Order {
        address trader;
        bool isBuy;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        uint256 price;
        uint256 deadline;
        bytes32 salt;
        address matchingValidator;
        uint256 nonce;
        address referrer;
        address referrer2;
    }

    function settleTrade(
        Order calldata makerOrder,
        Order calldata takerOrder,
        uint256 makerFillAmount,
        uint256 takerFillAmount,
        bytes calldata makerSignature,
        bytes calldata takerSignature
    ) external {
        makerSignature;
        takerSignature;
        // Pull the taker's tokenIn from the adapter (msg.sender).
        IERC20(takerOrder.tokenIn).transferFrom(
            msg.sender, address(this), takerFillAmount
        );
        // Pay the maker's tokenIn (= the taker's tokenOut) to the adapter.
        IERC20(makerOrder.tokenIn).transfer(msg.sender, makerFillAmount);
    }
}
