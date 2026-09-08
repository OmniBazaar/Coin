// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IMockATokenMintable
 * @author Omni Development DAO
 * @notice Test-only mintable aToken interface — production aTokens are
 *         minted by Aave's own logic; the mock uses a public `mint` for
 *         simplicity.
 */
interface IMockATokenMintable {
    /// @notice Mint `amount` aTokens to `to`.
    function mint(address to, uint256 amount) external;
}

/**
 * @title MockAaveV3Pool
 * @author Omni Development DAO
 * @notice Test-only mock of Aave V3's `Pool.supply()` entrypoint.
 *         Implements just enough behavior for the {OmniAaveAdapter}
 *         unit tests to exercise:
 *           - Pulls asset tokens from `msg.sender`
 *           - Mints aTokens 1:1 to `onBehalfOf`
 *
 *         Behavior knobs:
 *         - `mintRateBps`: aTokens minted per 1 unit of asset, in bps.
 *           Default 10_000 (1:1). Set lower to simulate a partial mint.
 *         - `forceZeroMint`: makes `supply` accept the asset but mint
 *           zero aTokens (exercises {OmniAaveAdapter.SupplyReturnedZeroATokens}).
 *         - `forceRevert`: makes `supply` revert.
 *         - `lastReferralCode`: written on every successful call so
 *           tests can verify the referral code was forwarded.
 * @dev NOT for production use. Test contract only.
 */
contract MockAaveV3Pool {
    using SafeERC20 for IERC20;

    /// @notice The aToken minted by `supply` (a test ERC20MockDecimals).
    IMockATokenMintable public immutable A_TOKEN;
    /// @notice aTokens minted per unit of asset, in basis points (10_000 = 1:1).
    uint16 public mintRateBps = 10_000;
    /// @notice When true, `supply` mints zero aTokens.
    bool public forceZeroMint;
    /// @notice When true, `supply` reverts.
    bool public forceRevert;
    /// @notice Referral code from the last successful `supply` call.
    uint16 public lastReferralCode;

    /// @notice Deploy a mock pool that mints the given aToken on supply.
    /// @param aToken Test aToken contract address (must expose `mint(address,uint256)`)
    constructor(address aToken) {
        A_TOKEN = IMockATokenMintable(aToken);
    }

    /// @notice Set the asset → aToken conversion rate for tests.
    /// @param bps Basis points (10_000 = 1:1)
    function setMintRateBps(uint16 bps) external {
        mintRateBps = bps;
    }

    /// @notice Toggle the `supply mints zero aTokens` failure mode.
    /// @param value true → next supply mints 0 aTokens
    function setForceZeroMint(bool value) external {
        forceZeroMint = value;
    }

    /// @notice Toggle the `supply reverts` failure mode.
    /// @param value true → next supply reverts
    function setForceRevert(bool value) external {
        forceRevert = value;
    }

    /// @notice Mock `Pool.supply` — pulls asset, mints aTokens to onBehalfOf.
    /// @param asset Underlying asset being deposited
    /// @param amount Amount of asset to deposit
    /// @param onBehalfOf Address that receives the aTokens
    /// @param referralCode Aave integrator referral code (stored as
    ///                     lastReferralCode for test verification)
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external {
        require(!forceRevert, "MockAaveV3Pool: forced revert");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        lastReferralCode = referralCode;
        if (forceZeroMint) {
            return;
        }
        uint256 aTokenAmount = (amount * mintRateBps) / 10_000;
        A_TOKEN.mint(onBehalfOf, aTokenAmount);
    }
}
