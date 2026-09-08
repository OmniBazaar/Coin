// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// ══════════════════════════════════════════════════════════════════════
//                           STATUS: CANONICAL (pXOM V2)
// ══════════════════════════════════════════════════════════════════════
// This is the CANONICAL pXOM V2, deployed on COTI V2 (2632500) at
// 0x958b07d5… — it extends the vendored COTI PrivateERC20 (Helium) and
// replaces the legacy hybrid that ran on OmniCoin L1 (88008) where the
// MPC precompile does not exist. The legacy L1 token is retired/paused.
// The constructor enforces block.chainid ∈ {2632500, 7082400} and reverts
// elsewhere. Do NOT remove — this is the live source of record for pXOM.
// ══════════════════════════════════════════════════════════════════════

import {PrivateERC20} from "../coti-helium/token/PrivateERC20/PrivateERC20.sol";

/**
 * @title PrivateOmniCoin
 * @author OmniCoin Development Team
 * @notice The canonical privacy-bearing representation of OmniCoin (XOM) on
 *         COTI V2 mainnet (chain id 2632500). 18 decimals, native 256-bit
 *         garbled balances (`ctUint256`), no public+private hybrid layer.
 * @dev Replaces the legacy `PrivateOmniCoin` (a hybrid that ran on the home
 *      chain 88008 where the MPC precompile does not exist and silently
 *      truncated 12 decimals via a 1e12 scaling factor on every shield).
 *
 *      Trust model: tokens minted here are 1:1 backed by XOM locked in
 *      `OmniPrivacyBridgeV2_L1` on chain 88008. The COTI-side bridge
 *      (`OmniPrivacyBridgeV2_COTI`) is the **only** address that holds
 *      `MINTER_ROLE`, and it can only mint after `IBridgeVerifier.verify`
 *      accepts a quorum attestation. Users can `burn` to queue a redemption
 *      back to L1 (the COTI-side bridge calls `burnPrivate` on this contract
 *      via the inherited public/encrypted burn path).
 *
 *      Hard chain guard: `block.chainid == 2632500` is enforced in the
 *      constructor. Helium 1.2.0's MPC precompile does not exist on
 *      OmniCoin L1 (88008) — deploying there would silently fail at
 *      runtime. The constructor revert is the loudest possible signal.
 */
contract PrivateOmniCoin is PrivateERC20 {
    /// @notice COTI V2 mainnet chain id.
    uint256 public constant COTI_CHAIN_ID = 2632500;

    /// @notice COTI V2 testnet chain id. Same MPC precompile semantics as mainnet, used for integration tests.
    uint256 public constant COTI_TESTNET_CHAIN_ID = 7082400;

    /// @notice Total mintable supply ceiling. Matches the L1 XOM cap (16.8B with 18 decimals).
    uint256 public constant SUPPLY_CAP = 16_800_000_000 * 10 ** 18;

    /// @notice Address authorised to mint pXOM (set once at construction; the bridge's deterministic deployment).
    address public immutable bridge;

    error WrongChain(uint256 actual, uint256 expected);
    error ZeroBridge();
    error CannotGrantMinterRole();

    /**
     * @notice Deploy the canonical pXOM contract on COTI V2.
     * @dev Grants `MINTER_ROLE` exclusively to the bridge address. Leaves
     *      `DEFAULT_ADMIN_ROLE` with the deployer (expected to be the
     *      OmniBazaar deployer multisig) so the role registry can be
     *      rotated if the bridge is ever migrated. The deployer does NOT
     *      receive `MINTER_ROLE` — minting power is bridge-only from t=0.
     * @param bridge_ Address of `OmniPrivacyBridgeV2_COTI` deployed on COTI 2632500.
     */
    constructor(address bridge_) PrivateERC20("Private OmniCoin", "pXOM") {
        if (block.chainid != COTI_CHAIN_ID && block.chainid != COTI_TESTNET_CHAIN_ID) {
            revert WrongChain(block.chainid, COTI_CHAIN_ID);
        }
        if (bridge_ == address(0)) revert ZeroBridge();
        bridge = bridge_;
        _grantRole(MINTER_ROLE, bridge_);
    }

    /// @inheritdoc PrivateERC20
    /// @notice 18-decimal precision throughout — no more 1e12 truncation.
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @inheritdoc PrivateERC20
    /// @notice Maximum mintable pXOM equals the L1 XOM total supply cap.
    function supplyCap() public pure override returns (uint256) {
        return SUPPLY_CAP;
    }

    /// @notice Prevent DEFAULT_ADMIN_ROLE from self-granting MINTER_ROLE.
    function grantRole(bytes32 role, address account) public override {
        if (role == MINTER_ROLE) revert CannotGrantMinterRole();
        super.grantRole(role, account);
    }
}
