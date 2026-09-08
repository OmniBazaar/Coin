// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {DEXSettlement} from "../dex/DEXSettlement.sol";

/**
 * @title DEXSettlementHarness
 * @notice Test-only harness exposing DEXSettlement's internal
 *         `_verifyFillAmounts` so a regression test can exercise the
 *         VT-04 zero-output guard directly.
 * @dev The public settle path (`settleTrade`/`settleTradesBatch`)
 *      runs `_verifyOrdersMatch` BEFORE `_verifyFillAmounts`, and
 *      `_verifyOrdersMatch` already rejects zero `amountOut` orders
 *      with `InvalidOrder()`. The VT-04 guard is therefore a
 *      defense-in-depth check at the fill-verification layer and is
 *      unreachable through the public surface; this harness lets the
 *      test assert the guard's own behavior.
 */
contract DEXSettlementHarness is DEXSettlement {
    constructor(
        address _liquidityPool,
        address _feeVault,
        address _oddaoTreasury,
        address trustedForwarder_
    ) DEXSettlement(_liquidityPool, _feeVault, _oddaoTreasury, trustedForwarder_) {}

    function verifyFillAmounts(
        Order calldata makerOrder,
        Order calldata takerOrder,
        uint256 makerFillAmount,
        uint256 takerFillAmount,
        bytes32 makerHash,
        bytes32 takerHash
    ) external view {
        _verifyFillAmounts(
            makerOrder,
            takerOrder,
            makerFillAmount,
            takerFillAmount,
            makerHash,
            takerHash
        );
    }
}
