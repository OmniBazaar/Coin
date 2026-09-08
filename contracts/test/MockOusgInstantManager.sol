// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IMockOusgMintable
 * @author Omni Development DAO
 * @notice Minimal mintable-OUSG interface the mock manager calls.
 *         Production OUSG has an `OusgMinter` role; we treat the mock
 *         OUSG ERC-20 as having a public `mint(address,uint256)` for
 *         test simplicity.
 */
interface IMockOusgMintable {
    /// @notice Mint `amount` OUSG to `to`. Open in mock; access-controlled
    ///         in production OUSG contract.
    function mint(address to, uint256 amount) external;
}

/**
 * @title MockOusgInstantManager
 * @author Omni Development DAO
 * @notice Test-only mock of Ondo's OUSGInstantManager. Implements the
 *         `mint(uint256 usdcAmountIn) returns (uint256 ousgAmountOut)`
 *         signature the production contract exposes (verified against
 *         the 2024-03 Code4rena audit source).
 *
 *         Behavior knobs for adversarial / edge-case testing:
 *         - `mintRateNumerator` / `mintRateDenominator`: configurable
 *           USDC → OUSG conversion. Default 1 USDC (6 dec) → 1 OUSG
 *           (18 dec) at a NAV of ~$110 (105.6e16 numerator, 1e6 denom).
 *         - `forceZeroOut`: makes `mint` return 0, exercising the
 *           adapter's `MintReturnedZero` revert path.
 *         - `forceRevert`: makes `mint` revert, simulating Ondo's
 *           rate-limit / paused / disallowed states.
 * @dev NOT for production use. Test contract only.
 */
contract MockOusgInstantManager {
    using SafeERC20 for IERC20;

    /// @notice USDC token the mock accepts (test ERC20Mock or TestUSDC).
    IERC20 public immutable USDC;
    /// @notice OUSG token the mock mints (test ERC20Mock with public mint).
    IMockOusgMintable public immutable OUSG;

    /// @notice Conversion rate numerator. Default 1.056e18 (NAV ~ $1.056
    ///         per OUSG with 18 decimals, vs $1 USDC with 6 decimals).
    uint256 public mintRateNumerator = 1_056_000_000_000_000_000;
    /// @notice Conversion rate denominator. Default 1e6 (USDC decimals).
    uint256 public mintRateDenominator = 1_000_000;

    /// @notice When true, `mint` returns zero (exercises MintReturnedZero path).
    bool public forceZeroOut;
    /// @notice When true, `mint` reverts (exercises adapter's atomic revert).
    bool public forceRevert;

    /// @notice Deploy a mock manager wired to a USDC + OUSG pair.
    /// @param usdc Test USDC ERC-20 address
    /// @param ousg Test OUSG mintable ERC-20 address
    constructor(address usdc, address ousg) {
        USDC = IERC20(usdc);
        OUSG = IMockOusgMintable(ousg);
    }

    /// @notice Set the USDC→OUSG conversion rate for tests.
    /// @param numerator   OUSG per USDC (scaled by denominator)
    /// @param denominator Scaling divisor
    function setMintRate(uint256 numerator, uint256 denominator) external {
        mintRateNumerator = numerator;
        mintRateDenominator = denominator;
    }

    /// @notice Toggle the `mint returns 0` failure mode.
    /// @param value true → next `mint` returns 0 + skips token mint
    function setForceZeroOut(bool value) external {
        forceZeroOut = value;
    }

    /// @notice Toggle the `mint reverts` failure mode.
    /// @param value true → next `mint` reverts unconditionally
    function setForceRevert(bool value) external {
        forceRevert = value;
    }

    /// @notice Production-shape entrypoint: pull USDC from caller, mint
    ///         OUSG to caller at the configured rate.
    /// @param usdcAmountIn USDC the caller is depositing
    /// @return ousgAmountOut OUSG minted to caller (msg.sender)
    function mint(uint256 usdcAmountIn) external returns (uint256 ousgAmountOut) {
        require(!forceRevert, "MockOusgManager: forced revert");

        USDC.safeTransferFrom(msg.sender, address(this), usdcAmountIn);

        if (forceZeroOut) {
            return 0;
        }

        ousgAmountOut = (usdcAmountIn * mintRateNumerator) / mintRateDenominator;
        OUSG.mint(msg.sender, ousgAmountOut);
    }
}
