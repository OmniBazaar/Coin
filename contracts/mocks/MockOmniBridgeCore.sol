// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MockOmniCore} from "./MockOmniCore.sol";

/**
 * @title MockOmniBridgeCore
 * @author OmniBazaar Team
 * @notice Extended MockOmniCore with getService() and hasRole() for OmniBridge tests
 * @dev Adds the service registry and access control methods that OmniBridge.sol calls:
 *      - `core.getService(bytes32)` for token address lookups
 *      - `core.hasRole(bytes32, address)` for admin authorization
 *      - `core.ADMIN_ROLE()` for the admin role identifier
 */
contract MockOmniBridgeCore is MockOmniCore {
    // ═══════════════════════════════════════════════════════════════════════
    //                          CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Admin role identifier (matches OmniCore.ADMIN_ROLE)
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Default admin role (matches OpenZeppelin AccessControl)
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    // ═══════════════════════════════════════════════════════════════════════
    //                          STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Service registry: service identifier => contract address
    mapping(bytes32 => address) private _services;

    /// @dev Role registry: role => account => hasRole
    mapping(bytes32 => mapping(address => bool)) private _roles;

    // ═══════════════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a service address is registered
    /// @param name Service identifier
    /// @param serviceAddress Address of the service contract
    event ServiceSet(bytes32 indexed name, address indexed serviceAddress);

    /// @notice Emitted when a role is granted
    /// @param role Role identifier
    /// @param account Account receiving the role
    event RoleGranted(bytes32 indexed role, address indexed account);

    /// @notice Emitted when a role is revoked
    /// @param role Role identifier
    /// @param account Account losing the role
    event RoleRevoked(bytes32 indexed role, address indexed account);

    // ═══════════════════════════════════════════════════════════════════════
    //                       MOCK SETTERS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Register a service address
     * @param name Service identifier (e.g., keccak256("OMNICOIN"))
     * @param serviceAddress Address of the service contract
     */
    function setService(bytes32 name, address serviceAddress) external {
        _services[name] = serviceAddress;
        emit ServiceSet(name, serviceAddress);
    }

    /**
     * @notice Grant a role to an account
     * @param role Role identifier
     * @param account Account to grant the role to
     */
    function grantRole(bytes32 role, address account) external {
        _roles[role][account] = true;
        emit RoleGranted(role, account);
    }

    /**
     * @notice Revoke a role from an account
     * @param role Role identifier
     * @param account Account to revoke the role from
     */
    function revokeRole(bytes32 role, address account) external {
        _roles[role][account] = false;
        emit RoleRevoked(role, account);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    INTERFACE IMPLEMENTATIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get service address by identifier
     * @param name Service identifier (bytes32)
     * @return serviceAddress Address of the registered service (address(0) if unset)
     */
    function getService(
        bytes32 name
    ) external view returns (address serviceAddress) {
        return _services[name];
    }

    /**
     * @notice Check if an account has a specific role
     * @param role Role identifier
     * @param account Account to check
     * @return True if the account has the role
     */
    function hasRole(
        bytes32 role,
        address account
    ) external view returns (bool) {
        return _roles[role][account];
    }
}
