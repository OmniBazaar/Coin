// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { OmniRegistration } from "./OmniRegistration.sol";

/**
 * @title OmniRegistrationTempAdmin
 * @author OmniBazaar
 * @notice TEMPORARY implementation of the {OmniRegistration} UUPS proxy used
 *         ONLY to perform the one-time admin backfill of the ~25 pre-launch
 *         accounts onto the on-chain `username -> address` record, then
 *         immediately reverted.
 *
 * @dev Lifecycle (deployer-direct, Pioneer phase):
 *      1. `upgradeToAndCall(thisImpl, 0x)` — point the proxy at this logic.
 *      2. Run the backfill: {adminRegisterWithName} for off-chain-only accounts
 *         and {adminBindUsername} for already-registered-but-unbound accounts.
 *      3. `upgradeToAndCall(0x1D85BB28…, 0x)` — point the proxy BACK at the
 *         original {OmniRegistration} implementation. These two admin functions
 *         vanish from the active logic; the bindings written in step 2 persist
 *         in the proxy's storage (the proxy never changes address).
 *
 *      Safety of the revert (the "five guardrails"):
 *        - Storage layout: this contract inherits {OmniRegistration} and
 *          declares ZERO new state variables — it only adds two functions.
 *          So the layout is byte-identical across original → temp → original
 *          and reverting is layout-safe.
 *        - UUPS machinery: `_authorizeUpgrade` (onlyRole DEFAULT_ADMIN_ROLE) and
 *          `proxiableUUID` are inherited unchanged, so while this temp logic is
 *          live the deployer can still upgrade BACK to the original.
 *        - No initializer is run on upgrade (call data `0x`), so proxy state is
 *          untouched.
 *
 *      Trust note: these admin functions let DEFAULT_ADMIN_ROLE (the deployer
 *      during Pioneer) author a binding WITHOUT the user's signature — a
 *      deliberate, one-time bootstrap deviation from the trustless invariant.
 *      It is bounded: a bound name is immutable ({_bindUsername} reverts on
 *      `UsernameTaken` / `UserAlreadyHasUsername`), the deployer registers each
 *      user's real address from the off-chain source of truth, and the
 *      capability is removed entirely by the step-3 revert. This contract must
 *      NEVER be the long-lived implementation.
 */
contract OmniRegistrationTempAdmin is OmniRegistration {
    /**
     * @notice Forward the immutable ERC-2771 trusted forwarder to the base.
     * @dev MUST be deployed with the SAME `trustedForwarder_` as the original
     *      implementation so meta-transaction behaviour is unchanged while this
     *      temp logic is live. The forwarder is an immutable in the impl
     *      bytecode (not proxy storage), so it does not affect the revert.
     * @param trustedForwarder_ The ERC-2771 forwarder address (OmniForwarder).
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder_) OmniRegistration(trustedForwarder_) {}

    /**
     * @notice Bind a username hash to an ALREADY-REGISTERED account on behalf
     *         of the user (admin backfill).
     * @dev For the cohort that registered on-chain before username binding
     *      shipped (their identity exists, their name does not). The
     *      reserved-set / already-taken / one-name-per-account guards are all
     *      enforced inside {_bindUsername}, which also emits {UsernameBound}.
     *      Reverts {NotRegistered} for an account with no on-chain registration
     *      — use {adminRegisterWithName} for those. No `nonReentrant`: there is
     *      no external call, so no reentrancy vector (and bytecode is at a
     *      premium — the original impl is already near the 24 KiB limit).
     * @param user The registered account to bind the name to.
     * @param usernameHash keccak256(bytes(lowercased username)).
     */
    function adminBindUsername(address user, bytes32 usernameHash)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (registrations[user].timestamp == 0) revert NotRegistered();
        _bindUsername(user, usernameHash);
    }

    /**
     * @notice Create a minimal base registration for an OFF-CHAIN-ONLY account
     *         and bind its username, in one transaction (admin backfill).
     * @dev For the cohort that registered off-chain only (Wallet / Mobile) and
     *      has no on-chain identity yet. Writes a minimal registration (KYC tier
     *      0, no referrer/phone/email) so {isRegistered} is true, then binds the
     *      name via {_bindUsername} (which emits {UsernameBound}). Email-
     *      uniqueness tracking is intentionally NOT set (the DB remains the
     *      email record) — this both keeps the function small and avoids any
     *      dependency on reproducing the validator's exact email normalization.
     *      Skips the daily rate-limit counter (admin batch, not open sign-up).
     *      Reverts {AlreadyRegistered} if the account already exists on-chain —
     *      use {adminBindUsername} for those.
     * @param user The account to register + bind.
     * @param usernameHash keccak256(bytes(lowercased username)).
     */
    function adminRegisterWithName(address user, bytes32 usernameHash)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (user == address(0)) revert ZeroAddress();
        if (registrations[user].timestamp != 0) revert AlreadyRegistered();

        // The AlreadyRegistered guard proves the slot is empty, so writing only
        // `timestamp` (which makes {isRegistered} true) suffices — every other
        // field is already its zero default (referrer 0, phone/email 0, kycTier
        // 0, bonuses false), which is exactly the intended minimal registration.
        // Provenance is recorded by the tx sender + the {UsernameBound} event,
        // so `registeredBy` is left 0. `totalRegistrations` is intentionally NOT
        // incremented here: it is a cosmetic stats counter with no safety role,
        // and writing one field instead of the full struct literal + counter
        // keeps this temporary impl under the 24 KiB code-size limit. The
        // registration is still real ({isRegistered} returns true).
        registrations[user].timestamp = block.timestamp; // solhint-disable-line not-rely-on-time

        // Either the registration + bind both land or both revert (the
        // reserved-set / taken / one-name guards live in {_bindUsername}).
        _bindUsername(user, usernameHash);
    }

    /**
     * @notice Marker so scripts can verify which implementation the proxy is
     *         pointed at. Present ONLY on this temp impl; the original
     *         {OmniRegistration} has no such selector, so a static call reverts
     *         there. Pure — consumes no storage. (Probing via `eth_call` is
     *         reliable on this subnet, unlike `eth_getStorageAt`.)
     * @return Always true.
     */
    function isTempAdminImpl() external pure returns (bool) {
        return true;
    }
}
