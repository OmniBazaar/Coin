// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title PioneerAllowlist
 * @author OmniCoin Development Team
 * @notice Pins the hash of the Pioneer founder allowlist on chain so that no
 *         operator can silently diverge the list their validator trusts.
 *
 * @dev VT-15. The founder allowlist is a comma-separated list of lowercased
 *      EVM addresses in the `PIONEER_FOUNDER_ALLOWLIST` env var, read from
 *      `.env.validator-N` on each host. An operator with root on a validator
 *      could edit that file to quietly admit accounts that were never meant to
 *      be cleared past the participation-score gate. This contract removes the
 *      silence: the canonical hash of the list is stored here, and every
 *      gateway/service node verifies its local list against {allowlistHash} at
 *      boot, failing closed (treating nobody as allowlisted) on a mismatch.
 *
 *      The pinned value is `keccak256` over the UTF-8 bytes of the list in
 *      canonical form: entries trimmed, lowercased, de-duplicated, sorted, and
 *      comma-joined without whitespace. Any independent verifier can reproduce
 *      the same bytes from the same address list.
 *
 *      Not upgradeable, on purpose — the value of a pin is that it does not
 *      move. `admin` is the deployer EOA during Pioneer phase and every
 *      administrative call is direct, with no timelock and no built-in delay,
 *      per the project's Pioneer-phase contract rule. The post-Pioneer
 *      handover to governance is a single {transferAdmin}.
 */
contract PioneerAllowlist {
    // ─────────────────────────────────────────────────────────── state ──

    /// @notice Holder of the administrative functions. The deployer, in Pioneer phase.
    address public admin;

    /// @notice The pinned allowlist hash. Zero until the deployer sets it.
    bytes32 public allowlistHash;

    // ────────────────────────────────────────────────────────── events ──

    /// @notice The pinned hash was changed.
    /// @param previousHash The hash that was in force.
    /// @param newHash The hash now in force.
    event AllowlistHashUpdated(
        bytes32 indexed previousHash,
        bytes32 indexed newHash
    );

    /// @notice Administrative control was transferred.
    /// @param previousAdmin The outgoing admin.
    /// @param newAdmin The incoming admin.
    event AdminTransferred(
        address indexed previousAdmin,
        address indexed newAdmin
    );

    // ────────────────────────────────────────────────────────── errors ──

    /// @notice A zero address was supplied where an account is required.
    error ZeroAddress();
    /// @notice The caller is not the admin.
    error NotAdmin(address caller);

    // ───────────────────────────────────────────────────────── modifier ──

    /// @dev Restricts a call to {admin}.
    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        _;
    }

    // ──────────────────────────────────────────────────── construction ──

    /**
     * @notice Deploy the pin.
     * @param initialAdmin The administrative account. The deployer EOA during
     *        Pioneer phase; a governance contract after the handover.
     */
    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert ZeroAddress();
        admin = initialAdmin;
        emit AdminTransferred(address(0), initialAdmin);
    }

    // ──────────────────────────────────────────────────────────── admin ──

    /**
     * @notice Replace the pinned allowlist hash.
     * @dev Takes effect immediately, with no delay, per the Pioneer-phase
     *      rule. The deployer pins the hash of a freshly chosen allowlist;
     *      every validator that disagrees with the new value fails closed at
     *      its next boot, so this call is how a legitimate list change is
     *      propagated and enforced.
     * @param newHash keccak256 of the canonical list, or zero to unpin.
     */
    function setHash(bytes32 newHash) external onlyAdmin {
        bytes32 previousHash = allowlistHash;
        allowlistHash = newHash;
        emit AllowlistHashUpdated(previousHash, newHash);
    }

    /**
     * @notice Hand administrative control to another account.
     * @dev The post-Pioneer migration to governance is this call and nothing
     *      else.
     * @param newAdmin The incoming admin.
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        address previousAdmin = admin;
        admin = newAdmin;
        emit AdminTransferred(previousAdmin, newAdmin);
    }
}
