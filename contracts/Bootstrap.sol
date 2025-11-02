// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title Bootstrap
 * @author OmniBazaar Development Team
 * @notice Lightweight bootstrap registry on Avalanche C-Chain for initial validator discovery
 * @dev This contract provides a minimal bootstrap mechanism for new validators to discover the network.
 *      It points to the OmniCore contract on Fuji Subnet-EVM and maintains a list of bootstrap validators.
 *
 *      Architecture:
 *      - Deployed on Avalanche C-Chain (mainnet/testnet)
 *      - Points to OmniCore.sol on Fuji Subnet-EVM (full registry)
 *      - Gateway validators: Tracked by avalanchego + OmniCore
 *      - Service nodes: Tracked only in OmniCore
 *
 *      Bootstrap validators are manually curated by admins and only updated when the composition changes.
 *
 * @custom:security-contact security@omnibazaar.com
 */
contract Bootstrap is AccessControl {
    /**
     * @notice Bootstrap validator information
     * @param active Whether this bootstrap validator is currently active
     * @param nodeAddress Validator's Ethereum address
     * @param multiaddr libp2p multiaddress for P2P connections
     * @param httpEndpoint HTTP API endpoint
     * @param wsEndpoint WebSocket endpoint
     * @param region Geographic region
     */
    struct BootstrapValidator {
        bool active;
        address nodeAddress;
        string multiaddr;
        string httpEndpoint;
        string wsEndpoint;
        string region;
    }

    /// @notice Role identifier for bootstrap administrator
    bytes32 public constant BOOTSTRAP_ADMIN_ROLE = keccak256("BOOTSTRAP_ADMIN_ROLE");

    /// @notice Address of OmniCore contract on Fuji Subnet-EVM
    address public omniCoreAddress;

    /// @notice Chain ID of the Fuji Subnet-EVM network
    uint256 public omniCoreChainId;

    /// @notice RPC URL for Fuji Subnet-EVM (off-chain reference)
    string public omniCoreRpcUrl;

    /// @notice List of bootstrap validator addresses
    address[] public bootstrapValidators;

    /// @notice Mapping from validator address to bootstrap info
    mapping(address => BootstrapValidator) public validatorInfo;

    /**
     * @notice Emitted when OmniCore reference is updated
     * @param omniCoreAddress New OmniCore contract address
     * @param chainId New chain ID
     * @param rpcUrl New RPC URL
     */
    event OmniCoreUpdated(
        address indexed omniCoreAddress,
        uint256 indexed chainId,
        string rpcUrl
    );

    /**
     * @notice Emitted when a bootstrap validator is added
     * @param nodeAddress Validator address
     * @param multiaddr libp2p multiaddress
     * @param httpEndpoint HTTP API endpoint
     */
    event BootstrapValidatorAdded(
        address indexed nodeAddress,
        string multiaddr,
        string httpEndpoint
    );

    /**
     * @notice Emitted when a bootstrap validator is removed
     * @param nodeAddress Validator address
     */
    event BootstrapValidatorRemoved(address indexed nodeAddress);

    /**
     * @notice Emitted when a bootstrap validator is updated
     * @param nodeAddress Validator address
     * @param multiaddr New libp2p multiaddress
     * @param httpEndpoint New HTTP API endpoint
     */
    event BootstrapValidatorUpdated(
        address indexed nodeAddress,
        string multiaddr,
        string httpEndpoint
    );

    /**
     * @notice Emitted when a bootstrap validator's active status changes
     * @param nodeAddress Validator address
     * @param active New active status
     */
    event BootstrapValidatorStatusChanged(
        address indexed nodeAddress,
        bool indexed active
    );

    /**
     * @notice Invalid address provided
     */
    error InvalidAddress();

    /**
     * @notice Invalid string parameter provided
     */
    error InvalidParameter();

    /**
     * @notice Invalid chain ID provided
     */
    error InvalidChainId();

    /**
     * @notice Validator already exists
     */
    error ValidatorAlreadyExists();

    /**
     * @notice Validator not active
     */
    error ValidatorNotActive();

    /**
     * @notice Validator not found
     */
    error ValidatorNotFound();

    /**
     * @notice Initializes the Bootstrap contract
     * @param _omniCoreAddress Address of OmniCore contract on Fuji Subnet-EVM
     * @param _omniCoreChainId Chain ID of Fuji Subnet-EVM
     * @param _omniCoreRpcUrl RPC URL for Fuji Subnet-EVM
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(
        address _omniCoreAddress,
        uint256 _omniCoreChainId,
        string memory _omniCoreRpcUrl
    ) {
        if (_omniCoreAddress == address(0)) revert InvalidAddress();
        if (_omniCoreChainId == 0) revert InvalidChainId();
        if (bytes(_omniCoreRpcUrl).length == 0) revert InvalidParameter();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BOOTSTRAP_ADMIN_ROLE, msg.sender);

        omniCoreAddress = _omniCoreAddress;
        omniCoreChainId = _omniCoreChainId;
        omniCoreRpcUrl = _omniCoreRpcUrl;

        emit OmniCoreUpdated(_omniCoreAddress, _omniCoreChainId, _omniCoreRpcUrl);
    }

    /**
     * @notice Updates the OmniCore contract reference
     * @dev Only callable by BOOTSTRAP_ADMIN_ROLE
     * @param _omniCoreAddress New OmniCore contract address on Fuji
     * @param _omniCoreChainId New chain ID
     * @param _omniCoreRpcUrl New RPC URL
     */
    function updateOmniCore(
        address _omniCoreAddress,
        uint256 _omniCoreChainId,
        string calldata _omniCoreRpcUrl
    ) external onlyRole(BOOTSTRAP_ADMIN_ROLE) {
        if (_omniCoreAddress == address(0)) revert InvalidAddress();
        if (_omniCoreChainId == 0) revert InvalidChainId();
        if (bytes(_omniCoreRpcUrl).length == 0) revert InvalidParameter();

        omniCoreAddress = _omniCoreAddress;
        omniCoreChainId = _omniCoreChainId;
        omniCoreRpcUrl = _omniCoreRpcUrl;

        emit OmniCoreUpdated(_omniCoreAddress, _omniCoreChainId, _omniCoreRpcUrl);
    }

    /**
     * @notice Adds a new bootstrap validator
     * @dev Only callable by BOOTSTRAP_ADMIN_ROLE
     * @param _nodeAddress Validator's Ethereum address
     * @param _multiaddr libp2p multiaddress
     * @param _httpEndpoint HTTP API endpoint
     * @param _wsEndpoint WebSocket endpoint
     * @param _region Geographic region
     */
    function addBootstrapValidator(
        address _nodeAddress,
        string calldata _multiaddr,
        string calldata _httpEndpoint,
        string calldata _wsEndpoint,
        string calldata _region
    ) external onlyRole(BOOTSTRAP_ADMIN_ROLE) {
        if (_nodeAddress == address(0)) revert InvalidAddress();
        if (bytes(_multiaddr).length == 0) revert InvalidParameter();
        if (bytes(_httpEndpoint).length == 0) revert InvalidParameter();
        if (bytes(_wsEndpoint).length == 0) revert InvalidParameter();
        if (validatorInfo[_nodeAddress].active) revert ValidatorAlreadyExists();

        BootstrapValidator memory validator = BootstrapValidator({
            active: true,
            nodeAddress: _nodeAddress,
            multiaddr: _multiaddr,
            httpEndpoint: _httpEndpoint,
            wsEndpoint: _wsEndpoint,
            region: _region
        });

        bootstrapValidators.push(_nodeAddress);
        validatorInfo[_nodeAddress] = validator;

        emit BootstrapValidatorAdded(_nodeAddress, _multiaddr, _httpEndpoint);
    }

    /**
     * @notice Removes a bootstrap validator
     * @dev Only callable by BOOTSTRAP_ADMIN_ROLE. Does not delete from mapping to preserve history.
     * @param _nodeAddress Validator address to remove
     */
    function removeBootstrapValidator(
        address _nodeAddress
    ) external onlyRole(BOOTSTRAP_ADMIN_ROLE) {
        if (!validatorInfo[_nodeAddress].active) revert ValidatorNotActive();

        validatorInfo[_nodeAddress].active = false;

        // Remove from array (expensive but bootstrap list is small)
        for (uint256 i = 0; i < bootstrapValidators.length; ++i) {
            if (bootstrapValidators[i] == _nodeAddress) {
                bootstrapValidators[i] = bootstrapValidators[bootstrapValidators.length - 1];
                bootstrapValidators.pop();
                break;
            }
        }

        emit BootstrapValidatorRemoved(_nodeAddress);
    }

    /**
     * @notice Updates bootstrap validator information
     * @dev Only callable by BOOTSTRAP_ADMIN_ROLE
     * @param _nodeAddress Validator address to update
     * @param _multiaddr New libp2p multiaddress
     * @param _httpEndpoint New HTTP API endpoint
     * @param _wsEndpoint New WebSocket endpoint
     * @param _region New geographic region
     */
    function updateBootstrapValidator(
        address _nodeAddress,
        string calldata _multiaddr,
        string calldata _httpEndpoint,
        string calldata _wsEndpoint,
        string calldata _region
    ) external onlyRole(BOOTSTRAP_ADMIN_ROLE) {
        if (!validatorInfo[_nodeAddress].active) revert ValidatorNotActive();
        if (bytes(_multiaddr).length == 0) revert InvalidParameter();
        if (bytes(_httpEndpoint).length == 0) revert InvalidParameter();
        if (bytes(_wsEndpoint).length == 0) revert InvalidParameter();

        BootstrapValidator storage validator = validatorInfo[_nodeAddress];
        validator.multiaddr = _multiaddr;
        validator.httpEndpoint = _httpEndpoint;
        validator.wsEndpoint = _wsEndpoint;
        validator.region = _region;

        emit BootstrapValidatorUpdated(_nodeAddress, _multiaddr, _httpEndpoint);
    }

    /**
     * @notice Sets a bootstrap validator's active status
     * @dev Only callable by BOOTSTRAP_ADMIN_ROLE
     * @param _nodeAddress Validator address
     * @param _active New active status
     */
    function setBootstrapValidatorStatus(
        address _nodeAddress,
        bool _active
    ) external onlyRole(BOOTSTRAP_ADMIN_ROLE) {
        if (validatorInfo[_nodeAddress].nodeAddress == address(0)) revert ValidatorNotFound();

        validatorInfo[_nodeAddress].active = _active;

        emit BootstrapValidatorStatusChanged(_nodeAddress, _active);
    }

    /**
     * @notice Gets all active bootstrap validators
     * @return addresses Array of validator addresses
     * @return infos Array of validator information
     */
    function getActiveBootstrapValidators()
        external
        view
        returns (
            address[] memory addresses,
            BootstrapValidator[] memory infos
        )
    {
        uint256 count = 0;

        // Count active validators
        for (uint256 i = 0; i < bootstrapValidators.length; ++i) {
            if (validatorInfo[bootstrapValidators[i]].active) {
                ++count;
            }
        }

        // Allocate arrays
        addresses = new address[](count);
        infos = new BootstrapValidator[](count);

        // Populate arrays
        uint256 index = 0;
        for (uint256 i = 0; i < bootstrapValidators.length; ++i) {
            address addr = bootstrapValidators[i];
            if (validatorInfo[addr].active) {
                addresses[index] = addr;
                infos[index] = validatorInfo[addr];
                ++index;
            }
        }

        return (addresses, infos);
    }

    /**
     * @notice Gets the number of active bootstrap validators
     * @return count Number of active validators
     */
    function getBootstrapValidatorCount() external view returns (uint256 count) {
        for (uint256 i = 0; i < bootstrapValidators.length; ++i) {
            if (validatorInfo[bootstrapValidators[i]].active) {
                ++count;
            }
        }
        return count;
    }

    /**
     * @notice Gets OmniCore contract information
     * @return _omniCoreAddress Address of OmniCore on Fuji
     * @return _chainId Chain ID of Fuji Subnet-EVM
     * @return _rpcUrl RPC URL for Fuji Subnet-EVM
     */
    function getOmniCoreInfo()
        external
        view
        returns (
            address _omniCoreAddress,
            uint256 _chainId,
            string memory _rpcUrl
        )
    {
        return (omniCoreAddress, omniCoreChainId, omniCoreRpcUrl);
    }
}
