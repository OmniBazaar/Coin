// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PrivateERC20} from "../coti-helium/token/PrivateERC20/PrivateERC20.sol";

/**
 * @title PrivateWETH
 * @author OmniCoin Development Team
 * @notice Private wrapped ETH on COTI V2 mainnet (chain id 2632500). 18 decimals,
 *         native 256-bit garbled balances. Backed 1:1 by WETH bridged via
 *         `OmniPrivacyBridgeV2_L1` on chain 88008.
 */
contract PrivateWETH is PrivateERC20 {
    /// @notice COTI V2 mainnet chain id. Constructor reverts on any other chain.
    uint256 public constant COTI_CHAIN_ID = 2632500;

    /// @notice COTI V2 testnet chain id.
    uint256 public constant COTI_TESTNET_CHAIN_ID = 7082400;

    /// @notice Hard mint ceiling for pWETH. 200M * 10^18 — generous headroom over ETH's ~120M circulating supply.
    uint256 public constant SUPPLY_CAP = 200_000_000 * 10 ** 18;

    /// @notice Address authorised to mint pWETH (the COTI-side bridge contract).
    address public immutable bridge;

    error WrongChain(uint256 actual, uint256 expected);
    error ZeroBridge();

    /**
     * @notice Deploy the canonical pWETH contract on COTI V2.
     * @param bridge_ Address of `OmniPrivacyBridgeV2_COTI` on COTI 2632500.
     */
    constructor(address bridge_) PrivateERC20("Private Wrapped ETH", "pWETH") {
        if (block.chainid != COTI_CHAIN_ID && block.chainid != COTI_TESTNET_CHAIN_ID) {
            revert WrongChain(block.chainid, COTI_CHAIN_ID);
        }
        if (bridge_ == address(0)) revert ZeroBridge();
        bridge = bridge_;
        _grantRole(MINTER_ROLE, bridge_);
    }

    /// @inheritdoc PrivateERC20
    /// @notice WETH's canonical 18-decimal representation.
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @inheritdoc PrivateERC20
    /// @notice Hard cap on cumulative pWETH mint (audit H-07).
    function supplyCap() public pure override returns (uint256) {
        return SUPPLY_CAP;
    }
}
