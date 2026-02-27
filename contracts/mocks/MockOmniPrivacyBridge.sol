// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockOmniPrivacyBridge
 * @author OmniBazaar Team
 * @notice Mock OmniPrivacyBridge for testing UnifiedFeeVault pXOM flows
 * @dev Simulates convertPXOMtoXOM(): burns pXOM from caller (via
 *      transferFrom to this contract then burn) and mints XOM to caller.
 *      Both pXOM and XOM must be MockERC20 with mint()/burn() functions.
 */
contract MockOmniPrivacyBridge {
    using SafeERC20 for IERC20;

    /// @notice pXOM token address
    address public pxomToken;

    /// @notice XOM token address
    address public xomToken;

    /// @notice Whether to revert on next conversion
    bool public shouldRevert;

    /**
     * @notice Deploy the mock privacy bridge
     * @param _pxom PrivateOmniCoin (pXOM) mock address
     * @param _xom OmniCoin (XOM) mock address
     */
    constructor(address _pxom, address _xom) {
        pxomToken = _pxom;
        xomToken = _xom;
    }

    /**
     * @notice Toggle whether conversions should revert
     * @param _shouldRevert Whether to revert
     */
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    /**
     * @notice Convert pXOM to XOM (mock implementation)
     * @dev Pulls pXOM from caller (must have approval), then mints
     *      an equal amount of XOM to the caller (no fee in mock).
     * @param amount Amount of pXOM to convert
     */
    function convertPXOMtoXOM(uint256 amount) external {
        require(
            !shouldRevert,
            "MockOmniPrivacyBridge: forced revert"
        );

        // Pull pXOM from caller (vault must approve this contract)
        IERC20(pxomToken).safeTransferFrom(
            msg.sender, address(this), amount
        );

        // Mint XOM to caller (simulates releasing locked XOM)
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = xomToken.call(
            abi.encodeWithSignature(
                "mint(address,uint256)",
                msg.sender,
                amount
            )
        );
        require(success, "MockOmniPrivacyBridge: mint failed");
    }
}
