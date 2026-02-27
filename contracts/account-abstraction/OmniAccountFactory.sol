// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

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
 *
 *      Rate limiting (M-01): An optional cooldown can be enabled by the
 *      deployer to limit how frequently a single msg.sender can create
 *      accounts. This mitigates sybil attacks that create many accounts
 *      to exhaust the OmniPaymaster's daily sponsorship budget.
 *
 *      Front-running (M-02): The deterministic CREATE2 addresses are
 *      publicly computable via getAddress(). An adversary who observes a
 *      pending createAccount() transaction can front-run it. However, the
 *      function is idempotent -- if the account already exists at the
 *      predicted address, it returns the existing one. The front-runner
 *      cannot change the owner or redirect funds. The only impact is that
 *      the front-runner's transaction triggers the AccountCreated event
 *      and increments accountCount instead of the original caller's.
 *      Off-chain systems SHOULD verify account ownership via owner()
 *      rather than relying on AccountCreated event attribution.
 */
contract OmniAccountFactory {
    using Clones for address;

    // ══════════════════════════════════════════════════════════════
    //                      STATE VARIABLES
    // ══════════════════════════════════════════════════════════════

    /// @notice The OmniAccount implementation contract (template for clones)
    address public immutable accountImplementation; // solhint-disable-line immutable-vars-naming

    /// @notice The ERC-4337 EntryPoint contract
    address public immutable entryPoint; // solhint-disable-line immutable-vars-naming

    /// @notice The deployer address that controls rate limiting settings
    address public immutable deployer; // solhint-disable-line immutable-vars-naming

    /// @notice Total number of accounts created (monotonically increasing)
    /// @dev This counter is never decremented. Do not use it as a count of
    ///      active accounts; index AccountCreated events off-chain instead.
    uint256 public accountCount;

    /// @notice Cooldown in seconds between account creations per msg.sender
    /// @dev M-01: Set to 0 to disable rate limiting (default).
    ///      When non-zero, each msg.sender must wait this many seconds
    ///      between createAccount calls.
    uint256 public creationCooldown;

    /// @notice Timestamp of last createAccount call per msg.sender
    mapping(address => uint256) public lastCreated;

    // ══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ══════════════════════════════════════════════════════════════

    /// @notice Emitted when a new smart account is deployed
    /// @param account Address of the deployed account
    /// @param owner Owner of the new account
    /// @param salt Salt used for CREATE2
    event AccountCreated(
        address indexed account,
        address indexed owner,
        uint256 indexed salt
    );

    /// @notice Emitted when the creation cooldown is updated
    /// @param newCooldown The new cooldown in seconds (0 = disabled)
    event CreationCooldownUpdated(uint256 indexed newCooldown);

    // ══════════════════════════════════════════════════════════════
    //                       CUSTOM ERRORS
    // ══════════════════════════════════════════════════════════════

    /// @notice Invalid address (zero)
    error InvalidAddress();

    /// @notice Account already exists at computed address
    error AccountAlreadyExists();

    /// @notice Caller must wait before creating another account
    error CreationCooldownNotMet();

    /// @notice Only the deployer can call this function
    error OnlyDeployer();

    // ══════════════════════════════════════════════════════════════
    //                       CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the factory and create the account implementation
     * @param entryPoint_ The ERC-4337 EntryPoint contract address
     */
    constructor(address entryPoint_) {
        if (entryPoint_ == address(0)) revert InvalidAddress();
        entryPoint = entryPoint_;
        deployer = msg.sender;
        accountImplementation = address(new OmniAccount(entryPoint_));
    }

    // ══════════════════════════════════════════════════════════════
    //                    EXTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Update the creation cooldown (M-01 rate limiting)
     * @dev Only callable by the deployer. Set to 0 to disable.
     * @param newCooldown Cooldown in seconds between creates per sender
     */
    function setCreationCooldown(uint256 newCooldown) external {
        if (msg.sender != deployer) revert OnlyDeployer();
        creationCooldown = newCooldown;
        emit CreationCooldownUpdated(newCooldown);
    }

    // ══════════════════════════════════════════════════════════════
    //                     PUBLIC FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Deploy a new smart account for the given owner
     * @dev Uses CREATE2 via ERC-1167 clones. Idempotent: if the account
     *      already exists, returns the existing address without reverting.
     *      The EntryPoint calls this via UserOperation.initCode:
     *      initCode = abi.encodePacked(
     *          factoryAddress,
     *          abi.encodeCall(createAccount, (owner, salt))
     *      )
     *
     *      M-01: Subject to optional creationCooldown rate limiting.
     *      M-02: Deterministic addresses are front-runnable but the
     *      function is idempotent, so front-running only affects event
     *      attribution, not account ownership or fund safety.
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
        address predicted = accountImplementation
            .predictDeterministicAddress(combinedSalt);

        // If account already exists, return it (idempotent)
        if (predicted.code.length > 0) {
            return predicted;
        }

        // M-01: Enforce rate limiting if configured
        _enforceRateLimit();

        // Deploy minimal proxy and initialize
        account = accountImplementation.cloneDeterministic(
            combinedSalt
        );
        OmniAccount(payable(account)).initialize(owner_);

        ++accountCount;
        emit AccountCreated(account, owner_, salt);
    }

    /**
     * @notice Compute the counterfactual address for an account
     * @dev Returns the address that createAccount would deploy to,
     *      without deploying. Useful for pre-computing addresses
     *      before the account exists on-chain.
     * @param owner_ The owner of the account
     * @param salt The salt for deterministic deployment
     * @return predicted The computed address
     */
    function getAddress(
        address owner_,
        uint256 salt
    ) external view returns (address predicted) {
        bytes32 combinedSalt = _computeSalt(owner_, salt);
        return accountImplementation
            .predictDeterministicAddress(combinedSalt);
    }

    // ══════════════════════════════════════════════════════════════
    //                    INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Enforce the creation cooldown rate limit
     * @dev M-01: Only enforces when creationCooldown > 0.
     *      Skips enforcement when cooldown is 0 (disabled).
     */
    /* solhint-disable not-rely-on-time */
    function _enforceRateLimit() internal {
        if (creationCooldown == 0) return;
        if (
            lastCreated[msg.sender] > 0
            && block.timestamp
                < lastCreated[msg.sender] + creationCooldown
        ) {
            revert CreationCooldownNotMet();
        }
        lastCreated[msg.sender] = block.timestamp;
    }
    /* solhint-enable not-rely-on-time */

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
