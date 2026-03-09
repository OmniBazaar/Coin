// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

/**
 * @title OmniForwarder
 * @author OmniCoin Development Team
 * @notice ERC-2771 trusted forwarder for gasless transactions on the OmniCoin L1 chain
 * @dev Thin deployment wrapper around OpenZeppelin's ERC2771Forwarder.
 *
 * Architecture:
 * - Users sign EIP-712 typed data (ForwardRequest) with their wallet
 * - Validators submit the signed request on-chain, paying gas on behalf of users
 * - The forwarder verifies the signature and appends the user's address to calldata
 * - Target contracts use ERC2771Context._msgSender() to recover the original user
 *
 * This enables fully gasless UX on the OmniCoin chain (chain ID 88008).
 * Users never need native tokens for gas — validators absorb all costs.
 *
 * EIP-712 domain: { name: "OmniForwarder", version: "1", chainId: 88008 }
 *
 * Inherited functionality from ERC2771Forwarder:
 * - execute(ForwardRequestData) — single meta-transaction relay
 * - executeBatch(ForwardRequestData[]) — atomic batch relay
 * - verify(ForwardRequestData) — off-chain signature verification
 * - nonces(address) — per-address auto-incrementing nonce
 * - Built-in EIP-712 signature verification and deadline checking
 *
 * Security:
 * - Nonce management prevents replay attacks
 * - Deadline checking prevents stale request submission
 * - Contract whitelisting is enforced off-chain by the validator relay service
 * - The forwarder itself has NO admin functions — it is fully permissionless
 */
contract OmniForwarder is ERC2771Forwarder {
    /**
     * @notice Deploy the OmniForwarder
     * @dev Sets the EIP-712 domain name to "OmniForwarder" for signature verification.
     *      The domain also includes version "1", the chain ID, and verifying contract address.
     */
    constructor() ERC2771Forwarder("OmniForwarder") {}
}
