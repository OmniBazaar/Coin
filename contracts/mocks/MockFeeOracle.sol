// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IFeeOracle} from "../dex/DEXSettlement.sol";

/**
 * @title MockFeeOracle
 * @author OmniCoin Development Team
 * @notice Mock implementation of IFeeOracle for testing.
 *         Returns a fixed discount for every trader/pair.
 */
contract MockFeeOracle is IFeeOracle {
    /// @notice Fixed discount returned by the oracle (basis points)
    uint256 public immutable fixedDiscount;

    /**
     * @notice Deploy mock oracle with a fixed discount
     * @param _fixedDiscount Discount in basis points
     */
    constructor(uint256 _fixedDiscount) {
        fixedDiscount = _fixedDiscount;
    }

    /// @inheritdoc IFeeOracle
    function getDiscountBps(
        address /* trader */,
        bytes32 /* pairHash */
    ) external view override returns (uint256 discountBps) {
        return fixedDiscount;
    }
}

/**
 * @title RevertingFeeOracle
 * @author OmniCoin Development Team
 * @notice Mock IFeeOracle that always reverts (for fail-open testing).
 */
contract RevertingFeeOracle is IFeeOracle {
    /// @inheritdoc IFeeOracle
    function getDiscountBps(
        address /* trader */,
        bytes32 /* pairHash */
    ) external pure override returns (uint256) {
        revert("Oracle broken");
    }
}
