// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PrivateERC20} from "../coti-helium/token/PrivateERC20/PrivateERC20.sol";

/**
 * @title PrivateUSDC
 * @author OmniCoin Development Team
 * @notice Private wrapped USDC on COTI V2 mainnet (chain id 2632500). 6 decimals,
 *         native 256-bit garbled balances. Backed 1:1 by USDC bridged via
 *         `OmniPrivacyBridgeV2_L1` on chain 88008.
 * @dev Same canonical-PrivateERC20 pattern as `PrivateOmniCoinV2`. Replaces
 *      the legacy hybrid `PrivateUSDC` which used `ctUint64` and the same
 *      precision-truncating scaling factor.
 */
contract PrivateUSDC is PrivateERC20 {
    /// @notice COTI V2 mainnet chain id. Constructor reverts on any other chain.
    uint256 public constant COTI_CHAIN_ID = 2632500;

    /// @notice COTI V2 testnet chain id.
    uint256 public constant COTI_TESTNET_CHAIN_ID = 7082400;

    /// @notice Hard mint ceiling for pUSDC. 100B * 10^6 = 4× headroom over USDC's circulating supply (~25B).
    /// @dev Belt-and-braces: bridges should never approach this; it bounds the worst case if MINTER_ROLE is ever escalated.
    uint256 public constant SUPPLY_CAP = 100_000_000_000 * 10 ** 6;

    /// @notice Address authorised to mint pUSDC (the COTI-side bridge contract).
    /// @dev Mutable with an admin-only migration setter (RT-02 remediation) so
    ///      a compromised / upgraded bridge can be rotated without redeploying
    ///      the token and migrating all encrypted MPC state.
    address public bridge;

    error WrongChain(uint256 actual, uint256 expected);
    error ZeroBridge();
    error CannotGrantMinterRole();

    /// @notice Emitted when the minting bridge is rotated.
    event BridgeUpdated(address indexed oldBridge, address indexed newBridge);

    /**
     * @notice Deploy the canonical pUSDC contract on COTI V2.
     * @param bridge_ Address of `OmniPrivacyBridgeV2_COTI` on COTI 2632500.
     */
    constructor(address bridge_) PrivateERC20("Private USDC", "pUSDC") {
        if (block.chainid != COTI_CHAIN_ID && block.chainid != COTI_TESTNET_CHAIN_ID) {
            revert WrongChain(block.chainid, COTI_CHAIN_ID);
        }
        if (bridge_ == address(0)) revert ZeroBridge();
        bridge = bridge_;
        _grantRole(MINTER_ROLE, bridge_);
    }

    /// @notice Prevent DEFAULT_ADMIN_ROLE from self-granting MINTER_ROLE.
    function grantRole(bytes32 role, address account) public override {
        if (role == MINTER_ROLE) revert CannotGrantMinterRole();
        super.grantRole(role, account);
    }

    /**
     * @notice Rotate the minting bridge (RT-02 remediation).
     * @dev Only DEFAULT_ADMIN_ROLE. Atomically revokes MINTER_ROLE from the
     *      old bridge and grants it to the new one, then updates the
     *      `bridge` reference. Uses `_grantRole`/`_revokeRole` directly so the
     *      {grantRole} MINTER_ROLE guard above is not tripped.
     * @param newBridge_ Address of the replacement bridge contract.
     */
    function setBridge(address newBridge_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBridge_ == address(0)) revert ZeroBridge();
        address oldBridge = bridge;
        _revokeRole(MINTER_ROLE, oldBridge);
        _grantRole(MINTER_ROLE, newBridge_);
        bridge = newBridge_;
        emit BridgeUpdated(oldBridge, newBridge_);
    }

    /// @inheritdoc PrivateERC20
    /// @notice USDC's canonical 6-decimal representation.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @inheritdoc PrivateERC20
    /// @notice Hard cap on cumulative pUSDC mint (audit H-07).
    function supplyCap() public pure override returns (uint256) {
        return SUPPLY_CAP;
    }
}
