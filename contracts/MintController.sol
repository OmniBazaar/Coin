// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MintController
 * @author OmniCoin Development Team
 * @notice Enforces a hard supply cap on OmniCoin (XOM) minting
 * @dev Wraps OmniCoin's mint() function with an immutable MAX_SUPPLY check.
 *
 * Deployment model:
 *   1. Deploy MintController with the OmniCoin token address
 *   2. Grant MINTER_ROLE on OmniCoin to this MintController
 *   3. Revoke MINTER_ROLE from the deployer on OmniCoin
 *   4. All future minting flows through this contract
 *
 * The MAX_SUPPLY constant (16.6 billion XOM) matches published tokenomics.
 * Once totalSupply() reaches this cap, no further minting is possible —
 * there is no admin override, upgrade path, or emergency bypass.
 */
contract MintController is AccessControl {
    // ──────────────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Role identifier for addresses authorized to mint via this controller
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Maximum total supply of XOM tokens (16.6 billion with 18 decimals)
    uint256 public constant MAX_SUPPLY = 16_600_000_000e18;

    // ──────────────────────────────────────────────────────────────────────
    // Immutable state
    // ──────────────────────────────────────────────────────────────────────

    /// @notice The OmniCoin token contract
    IERC20 public immutable TOKEN;

    // ──────────────────────────────────────────────────────────────────────
    // Custom errors
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Thrown when a mint would exceed MAX_SUPPLY
    /// @param requested The amount requested to mint
    /// @param remaining The remaining mintable supply
    error MaxSupplyExceeded(uint256 requested, uint256 remaining);

    /// @notice Thrown when mint amount is zero
    error ZeroAmount();

    /// @notice Thrown when recipient address is the zero address
    error InvalidAddress();

    // ──────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Emitted when tokens are minted through the controller
    /// @param to Recipient address
    /// @param amount Amount minted (in wei)
    /// @param newTotalSupply Total supply after minting
    event ControlledMint(
        address indexed to,
        uint256 amount,
        uint256 newTotalSupply
    );

    // ──────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Deploy the MintController
     * @param token_ The OmniCoin token contract address
     * @dev Grants DEFAULT_ADMIN_ROLE and MINTER_ROLE to the deployer.
     *      The deployer should transfer admin to the TimelockController
     *      and grant MINTER_ROLE to authorized minting services
     *      (e.g., BlockRewardService, BonusService) before revoking
     *      their own roles.
     */
    constructor(address token_) {
        if (token_ == address(0)) revert InvalidAddress();

        TOKEN = IERC20(token_);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    // ──────────────────────────────────────────────────────────────────────
    // External functions
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Mint new XOM tokens, enforcing the supply cap
     * @param to Recipient address
     * @param amount Amount to mint (in wei, 18 decimals)
     * @dev Reverts if:
     *   - Caller lacks MINTER_ROLE
     *   - amount is zero
     *   - to is address(0)
     *   - totalSupply() + amount > MAX_SUPPLY
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert InvalidAddress();

        uint256 currentSupply = TOKEN.totalSupply();
        uint256 remaining = MAX_SUPPLY > currentSupply
            ? MAX_SUPPLY - currentSupply
            : 0;

        if (amount > remaining) {
            revert MaxSupplyExceeded(amount, remaining);
        }

        // Call OmniCoin's mint function (requires this contract has MINTER_ROLE on OmniCoin)
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returnData) = address(TOKEN).call(
            abi.encodeWithSignature("mint(address,uint256)", to, amount)
        );
        // solhint-disable-next-line reason-string
        require(success, string(returnData));

        emit ControlledMint(to, amount, currentSupply + amount);
    }

    // ──────────────────────────────────────────────────────────────────────
    // View functions
    // ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Get the maximum supply cap
     * @return The MAX_SUPPLY constant (16.6 billion XOM in wei)
     */
    function maxSupplyCap() external pure returns (uint256) {
        return MAX_SUPPLY;
    }

    /**
     * @notice Get the remaining mintable supply
     * @return The number of tokens that can still be minted before hitting the cap
     */
    function remainingMintable() external view returns (uint256) {
        uint256 currentSupply = TOKEN.totalSupply();
        if (currentSupply >= MAX_SUPPLY) {
            return 0;
        }
        return MAX_SUPPLY - currentSupply;
    }

    /**
     * @notice Get the current total supply of the token
     * @return The current totalSupply from the OmniCoin contract
     */
    function currentSupply() external view returns (uint256) {
        return TOKEN.totalSupply();
    }
}
