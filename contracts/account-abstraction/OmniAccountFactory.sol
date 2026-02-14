// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {OmniAccount} from "./OmniAccount.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title OmniAccountFactory
 * @author OmniCoin Development Team
 * @notice Factory contract for deploying OmniAccount smart wallets via CREATE2
 * @dev Uses ERC-1167 minimal proxies (clones) for gas-efficient deployment.
 *      Each account is deterministic based on (owner, salt), allowing
 *      counterfactual address computation before deployment.
 *      The EntryPoint calls this factory via UserOperation.initCode.
 */
contract OmniAccountFactory {
    using Clones for address;

    // ══════════════════════════════════════════════════════════════
    //                      STATE VARIABLES
    // ══════════════════════════════════════════════════════════════

    /// @notice The OmniAccount implementation contract (template for clones)
    address public immutable accountImplementation;

    /// @notice The ERC-4337 EntryPoint contract
    address public immutable entryPoint;

    /// @notice Total number of accounts created
    uint256 public accountCount;

    // ══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ══════════════════════════════════════════════════════════════

    /// @notice Emitted when a new smart account is deployed
    /// @param account Address of the deployed account
    /// @param owner Owner of the new account
    /// @param salt Salt used for CREATE2
    event AccountCreated(address indexed account, address indexed owner, uint256 salt);

    // ══════════════════════════════════════════════════════════════
    //                       CUSTOM ERRORS
    // ══════════════════════════════════════════════════════════════

    /// @notice Invalid address (zero)
    error InvalidAddress();

    /// @notice Account already exists at computed address
    error AccountAlreadyExists();

    // ══════════════════════════════════════════════════════════════
    //                       CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the factory and create the account implementation template
     * @param entryPoint_ The ERC-4337 EntryPoint contract address
     */
    constructor(address entryPoint_) {
        if (entryPoint_ == address(0)) revert InvalidAddress();
        entryPoint = entryPoint_;
        accountImplementation = address(new OmniAccount(entryPoint_));
    }

    // ══════════════════════════════════════════════════════════════
    //                     PUBLIC FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Deploy a new smart account for the given owner
     * @dev Uses CREATE2 via ERC-1167 clones. If the account already exists,
     *      returns the existing address without reverting (idempotent).
     *      The EntryPoint calls this via UserOperation.initCode:
     *      initCode = abi.encodePacked(factoryAddress, abi.encodeCall(createAccount, (owner, salt)))
     * @param owner_ The owner of the new account
     * @param salt Unique salt for deterministic deployment
     * @return account The address of the (new or existing) account
     */
    function createAccount(
        address owner_,
        uint256 salt
    ) external returns (address account) {
        if (owner_ == address(0)) revert InvalidAddress();

        bytes32 combinedSalt = _computeSalt(owner_, salt);
        address predicted = accountImplementation.predictDeterministicAddress(combinedSalt);

        // If account already exists, return it (idempotent)
        if (predicted.code.length > 0) {
            return predicted;
        }

        // Deploy minimal proxy and initialize
        account = accountImplementation.cloneDeterministic(combinedSalt);
        OmniAccount(payable(account)).initialize(owner_);

        ++accountCount;
        emit AccountCreated(account, owner_, salt);
    }

    /**
     * @notice Compute the counterfactual address for an account
     * @dev Returns the address that createAccount would deploy to, without deploying.
     *      Useful for pre-computing addresses before the account exists on-chain.
     * @param owner_ The owner of the account
     * @param salt The salt for deterministic deployment
     * @return predicted The computed address
     */
    function getAddress(
        address owner_,
        uint256 salt
    ) external view returns (address predicted) {
        bytes32 combinedSalt = _computeSalt(owner_, salt);
        return accountImplementation.predictDeterministicAddress(combinedSalt);
    }

    // ══════════════════════════════════════════════════════════════
    //                    INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Combine owner address and salt into a single CREATE2 salt
     * @param owner_ The account owner
     * @param salt The user-provided salt
     * @return The combined salt
     */
    function _computeSalt(
        address owner_,
        uint256 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner_, salt));
    }
}
