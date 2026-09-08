// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ILPZapReentry
 * @author OmniBazaar Team
 * @notice Minimal LPZap surface re-entered by {ReentrantZapToken}
 * @dev Only the two nonReentrant entry points are needed for the probe.
 */
interface ILPZapReentry {
    /// @notice LPZap.zapIn entry point
    /// @param usdcAmount USDC to zap in
    /// @param minXOMOut Minimum XOM from the swap step
    /// @param minLPOut Minimum LP tokens expected
    /// @param deadline Transaction deadline
    /// @return lpReceived LP tokens minted
    function zapIn(
        uint256 usdcAmount,
        uint256 minXOMOut,
        uint256 minLPOut,
        uint256 deadline
    ) external returns (uint256 lpReceived);

    /// @notice LPZap.zapOut entry point
    /// @param lpAmount LP tokens to zap out
    /// @param minXOMFromLP Minimum XOM from removeLiquidity
    /// @param minUSDCOut Minimum total USDC expected
    /// @param deadline Transaction deadline
    /// @return usdcReturned USDC returned
    function zapOut(
        uint256 lpAmount,
        uint256 minXOMFromLP,
        uint256 minUSDCOut,
        uint256 deadline
    ) external returns (uint256 usdcReturned);
}

/**
 * @title ReentrantZapToken
 * @author OmniBazaar Team — TEST ONLY
 * @notice Malicious ERC-20 that re-enters {LPZap} from inside `transferFrom`
 *         and `transfer`, proving the `nonReentrant` guard blocks reentrancy.
 * @dev Wired into a dedicated LPZap instance as the `usdc` token. On the first
 *      token movement during an outer zap the armed payload re-enters the LPZap
 *      (zapIn or zapOut); the guard reverts with `ReentrancyGuardReentrantCall`,
 *      which bubbles up and reverts the outer call. NOT for production.
 */
contract ReentrantZapToken is ERC20 {
    /// @notice LPZap instance re-entered while armed
    address public target;

    /// @notice Whether the reentrancy payload is armed
    bool public armed;

    /// @notice When true the payload re-enters zapOut, otherwise zapIn
    bool public attackZapOut;

    /**
     * @notice Deploy the malicious token and mint test supply to the deployer
     */
    constructor() ERC20("ReentrantZapToken", "REVIL") {
        _mint(msg.sender, 1_000_000 ether);
    }

    /**
     * @notice Mint tokens to an address (test convenience)
     * @param to Recipient
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Arm the reentrancy payload
     * @param target_ LPZap contract to re-enter
     * @param attackZapOut_ True to re-enter zapOut, false for zapIn
     */
    function arm(address target_, bool attackZapOut_) external {
        target = target_;
        attackZapOut = attackZapOut_;
        armed = true;
    }

    /**
     * @notice transferFrom override that re-enters the target once while armed
     * @param from Source address
     * @param to Destination address
     * @param amount Amount to transfer
     * @return success True on success (reverts on blocked reentrancy)
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool success) {
        _reenter();
        return super.transferFrom(from, to, amount);
    }

    /**
     * @notice transfer override that re-enters the target once while armed
     * @param to Destination address
     * @param amount Amount to transfer
     * @return success True on success (reverts on blocked reentrancy)
     */
    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool success) {
        _reenter();
        return super.transfer(to, amount);
    }

    /**
     * @notice Fire the armed reentrant call exactly once
     * @dev Disarms first so the reentrant call cannot recurse further. The
     *      reentrant zap reverts on the guard; the revert bubbles to the
     *      outer caller.
     */
    function _reenter() private {
        if (armed && target != address(0)) {
            armed = false;
            if (attackZapOut) {
                ILPZapReentry(target).zapOut(1, 0, 0, type(uint256).max);
            } else {
                ILPZapReentry(target).zapIn(1, 0, 0, type(uint256).max);
            }
        }
    }
}
