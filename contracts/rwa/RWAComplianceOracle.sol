// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRWAComplianceOracle} from "./interfaces/IRWAComplianceOracle.sol";

/**
 * @title RWAComplianceOracle
 * @author OmniCoin Development Team
 * @notice On-chain compliance verification for RWA tokens
 * @dev Delegates compliance checking to individual token contracts
 *
 * Supported Token Standards:
 * - ERC-20: Basic tokens (no compliance requirements)
 * - ERC-3643: T-REX security tokens with canTransfer()
 * - ERC-1400: Security tokens with canTransferByPartition()
 * - ERC-4626: Tokenized vaults (classified but no special compliance)
 *
 * KYC Tier Requirements by Token Class:
 *   - ERC-20 tokens: No KYC required (kycRequired = false)
 *   - ERC-3643 (T-REX): KYC required (kycRequired = true). The
 *     token's own identity registry enforces investor verification.
 *     Accredited investor status is NOT required by default.
 *   - ERC-1400 (Polymath): KYC and accredited investor status both
 *     required (kycRequired = true, accreditedInvestorRequired = true).
 *     These are typically institutional-grade securities with stricter
 *     transfer restrictions.
 *   - ERC-4626 vaults: No additional compliance (same as ERC-20).
 *     The underlying vault asset may have its own compliance, but the
 *     vault token itself is treated as a standard ERC-20.
 *
 * Key Features:
 * - Standard auto-detection via ERC-165 and function probing
 * - Compliance result caching (5-minute TTL, registrar-only refresh)
 * - Batch compliance checking (max 50 per call)
 * - Graceful degradation on external call failures (CHECK_FAILED)
 * - Fail-closed default: unregistered tokens return NON_COMPLIANT
 *
 * Admin Security:
 *   The `registrar` role controls all token registration, configuration,
 *   cache management, and registrar transfer. For production deployment,
 *   the registrar address MUST be a multisig (e.g., Gnosis Safe) or the
 *   OmniGovernance timelock contract. A single EOA registrar is acceptable
 *   only for testnet deployments. The registrar can be transferred via
 *   setRegistrar(), which should use a 2-step transfer pattern in future
 *   versions to prevent accidental transfers to incorrect addresses.
 *
 * Security Features:
 * - Reentrancy protection on state-modifying functions
 * - Safe external calls via try/catch
 * - Fail-closed compliance default for unregistered tokens
 */
contract RWAComplianceOracle is IRWAComplianceOracle, ReentrancyGuard {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Cache TTL in seconds (5 minutes)
    uint256 public constant CACHE_TTL = 5 minutes;

    /// @notice ERC-3643 interface ID
    bytes4 private constant ERC3643_INTERFACE = 0x3c4f3a45;

    /// @notice ERC-1400 interface ID
    bytes4 private constant ERC1400_INTERFACE = 0x985e8bff;

    /// @notice ERC-4626 asset() function selector for probing
    /// @dev ERC-4626 has no standardized ERC-165 ID; we probe for
    ///      asset() (0x38d52e0f) which is unique to ERC-4626 vaults.
    ///      The previous value 0x7ecebe00 was EIP-2612 nonces().
    bytes4 private constant ERC4626_ASSET_SELECTOR = 0x38d52e0f;

    /// @notice Maximum batch size for compliance checks
    uint256 public constant MAX_BATCH_SIZE = 50;

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice Token configurations
    mapping(address => TokenConfig) private _tokenConfigs;

    /// @notice Compliance cache: user => token => result
    mapping(address => mapping(address => ComplianceResult)) private _complianceCache;

    /// @notice List of registered tokens
    address[] private _registeredTokens;

    /// @notice Registrar address (can register tokens)
    address public registrar;

    // ========================================================================
    // EVENTS (Additional)
    // ========================================================================

    /// @notice Emitted when registrar is updated
    /// @param oldRegistrar Previous registrar
    /// @param newRegistrar New registrar
    event RegistrarUpdated(address indexed oldRegistrar, address indexed newRegistrar);

    /// @notice Emitted when a token configuration is updated
    /// @param token Token address
    /// @param complianceContract New compliance contract
    /// @param complianceEnabled Whether compliance is enabled
    event TokenConfigUpdated(
        address indexed token,
        address indexed complianceContract,
        bool indexed complianceEnabled
    );

    /// @notice Emitted when a token is deregistered
    /// @param token Token address
    event TokenDeregistered(address indexed token);

    // ========================================================================
    // ERRORS (Additional)
    // ========================================================================

    /// @notice Thrown when caller is not registrar
    error NotRegistrar();

    /// @notice Thrown when token already registered
    error TokenAlreadyRegistered(address token);

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when array lengths don't match
    /// @param usersLength Users array length
    /// @param tokensLength Tokens array length
    error ArrayLengthMismatch(uint256 usersLength, uint256 tokensLength);

    /// @notice Thrown when batch size exceeds maximum
    /// @param provided Provided batch size
    /// @param maxAllowed Maximum allowed batch size
    error BatchSizeTooLarge(uint256 provided, uint256 maxAllowed);

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    /**
     * @notice Only registrar can call
     */
    modifier onlyRegistrar() {
        if (msg.sender != registrar) revert NotRegistrar();
        _;
    }

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /**
     * @notice Deploy compliance oracle
     * @param _registrar Initial registrar address
     */
    constructor(address _registrar) {
        if (_registrar == address(0)) revert ZeroAddress();
        registrar = _registrar;
    }

    // ========================================================================
    // REGISTRATION FUNCTIONS
    // ========================================================================

    /**
     * @inheritdoc IRWAComplianceOracle
     */
    function registerToken(
        address token,
        address complianceContract
    ) external override onlyRegistrar {
        if (token == address(0)) revert ZeroAddress();
        if (_tokenConfigs[token].registered) revert TokenAlreadyRegistered(token);

        // Detect token standard
        TokenStandard standard = _detectTokenStandard(token);

        // Store configuration
        _tokenConfigs[token] = TokenConfig({
            standard: standard,
            registered: true,
            complianceEnabled: standard != TokenStandard.ERC20,
            complianceContract: complianceContract != address(0) ? complianceContract : token,
            // solhint-disable-next-line not-rely-on-time
            lastUpdated: block.timestamp
        });

        _registeredTokens.push(token);

        emit TokenRegistered(token, standard, complianceContract);
    }

    /**
     * @notice Update configuration for a registered token
     * @dev Allows the registrar to change the compliance contract,
     *      enable/disable compliance, or correct misconfigurations
     *      without requiring a new oracle deployment.
     * @param token Token address to update
     * @param complianceContract New compliance contract address
     * @param complianceEnabled Whether compliance is enabled
     */
    function updateTokenConfig(
        address token,
        address complianceContract,
        bool complianceEnabled
    ) external onlyRegistrar {
        if (!_tokenConfigs[token].registered) {
            revert TokenNotRegistered(token);
        }

        TokenConfig storage config = _tokenConfigs[token];
        config.complianceContract = complianceContract != address(0)
            ? complianceContract
            : token;
        config.complianceEnabled = complianceEnabled;
        // solhint-disable-next-line not-rely-on-time
        config.lastUpdated = block.timestamp;

        emit TokenConfigUpdated(
            token, complianceContract, complianceEnabled
        );
    }

    /**
     * @notice Deregister a token from the compliance oracle
     * @dev Marks the token as unregistered. Does not remove from
     *      _registeredTokens array (gas cost prohibitive for on-chain
     *      array removal). Deregistered tokens will be treated as
     *      NON_COMPLIANT per the fail-closed default.
     * @param token Token address to deregister
     */
    function deregisterToken(
        address token
    ) external onlyRegistrar {
        if (!_tokenConfigs[token].registered) {
            revert TokenNotRegistered(token);
        }

        _tokenConfigs[token].registered = false;
        _tokenConfigs[token].complianceEnabled = false;

        emit TokenDeregistered(token);
    }

    /**
     * @notice Update registrar address
     * @param newRegistrar New registrar address
     */
    function setRegistrar(address newRegistrar) external onlyRegistrar {
        if (newRegistrar == address(0)) revert ZeroAddress();
        address oldRegistrar = registrar;
        registrar = newRegistrar;
        emit RegistrarUpdated(oldRegistrar, newRegistrar);
    }

    // ========================================================================
    // COMPLIANCE CHECKING
    // ========================================================================

    /* solhint-disable code-complexity */
    /**
     * @notice Check if a user is compliant for a given token
     * @dev Checks cache first, then evaluates compliance based on
     *      token standard. Unregistered tokens default to NON_COMPLIANT
     *      (fail-closed). The cache is only populated when the registrar
     *      explicitly calls refreshCompliance(). For on-chain callers
     *      (e.g., RWAAMM), the cache will rarely hit since no on-chain
     *      path writes to it. The cache is primarily useful for off-chain
     *      consumers that first call refreshCompliance() and then read
     *      via this function within the 5-minute TTL window.
     * @param user User address
     * @param token Token address
     * @return result Compliance result with status and details
     */
    function checkCompliance(
        address user,
        address token
    ) external view override returns (ComplianceResult memory result) {
        // Check cache first (populated by registrar via refreshCompliance)
        ComplianceResult memory cached = _complianceCache[user][token];
        // solhint-disable-next-line not-rely-on-time
        if (cached.validUntil > block.timestamp) {
            return cached;
        }

        // Delegate to internal implementation (avoids external self-calls)
        return _checkComplianceInternal(user, token);
    }
    /* solhint-enable code-complexity */

    /**
     * @inheritdoc IRWAComplianceOracle
     */
    function checkSwapCompliance(
        address user,
        address tokenIn,
        address tokenOut,
        uint256 /* amountIn */
    ) external view override returns (
        bool inputCompliant,
        bool outputCompliant,
        string memory reason
    ) {
        // Check input token compliance (internal call, no external overhead)
        ComplianceResult memory inputResult = _checkComplianceInternal(user, tokenIn);
        inputCompliant = inputResult.status == ComplianceStatus.COMPLIANT;

        // Check output token compliance (internal call, no external overhead)
        ComplianceResult memory outputResult = _checkComplianceInternal(user, tokenOut);
        outputCompliant = outputResult.status == ComplianceStatus.COMPLIANT;

        // Build combined reason
        if (!inputCompliant && !outputCompliant) {
            reason = string(abi.encodePacked(
                "Input: ", inputResult.reason, "; Output: ", outputResult.reason
            ));
        } else if (!inputCompliant) {
            reason = inputResult.reason;
        } else if (!outputCompliant) {
            reason = outputResult.reason;
        } else {
            reason = "Compliant";
        }
    }

    /* solhint-disable ordering */
    /**
     * @notice Refresh cached compliance for a user/token pair
     * @dev Restricted to registrar only to prevent cache poisoning.
     *      An attacker could otherwise call refreshCompliance() during
     *      a compliance contract reconfiguration window to cache
     *      stale or permissive results for the full TTL period.
     * @param user User address to refresh compliance for
     * @param token Token address to refresh compliance for
     */
    function refreshCompliance(
        address user,
        address token
    ) external override onlyRegistrar nonReentrant {
        // Re-check compliance and update cache (internal call)
        ComplianceResult memory result = _checkComplianceInternal(user, token);

        _complianceCache[user][token] = result;

        emit ComplianceCached(user, token, result.validUntil);
    }
    /* solhint-enable ordering */

    /**
     * @notice Invalidate a cached compliance result immediately
     * @dev Allows the registrar to force re-evaluation on next check.
     *      Use when a compliance contract is being updated/reconfigured.
     * @param user User address
     * @param token Token address
     */
    function invalidateCache(
        address user,
        address token
    ) external onlyRegistrar {
        delete _complianceCache[user][token];
    }

    /**
     * @inheritdoc IRWAComplianceOracle
     */
    function batchCheckCompliance(
        address[] calldata users,
        address[] calldata tokens
    ) external view override returns (ComplianceResult[] memory results) {
        if (users.length != tokens.length) {
            revert ArrayLengthMismatch(users.length, tokens.length);
        }
        if (users.length > MAX_BATCH_SIZE) {
            revert BatchSizeTooLarge(users.length, MAX_BATCH_SIZE);
        }

        results = new ComplianceResult[](users.length);

        for (uint256 i = 0; i < users.length; ++i) {
            results[i] = _checkComplianceInternal(users[i], tokens[i]);
        }
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /**
     * @inheritdoc IRWAComplianceOracle
     */
    function getTokenConfig(
        address token
    ) external view override returns (TokenConfig memory config) {
        return _tokenConfigs[token];
    }

    /**
     * @inheritdoc IRWAComplianceOracle
     */
    function isTokenRegistered(address token) external view override returns (bool registered) {
        return _tokenConfigs[token].registered;
    }

    /**
     * @inheritdoc IRWAComplianceOracle
     */
    function detectTokenStandard(address token) external view override returns (TokenStandard standard) {
        return _detectTokenStandard(token);
    }

    /**
     * @inheritdoc IRWAComplianceOracle
     */
    function complianceCacheTTL() external pure override returns (uint256 ttl) {
        return CACHE_TTL;
    }

    /**
     * @notice Get all registered tokens (bounded by array size)
     * @dev For large registries, use getRegisteredTokensPaginated instead
     * @return Array of registered token addresses
     */
    function getRegisteredTokens() external view returns (address[] memory) {
        return _registeredTokens;
    }

    /**
     * @notice Get registered tokens with pagination
     * @dev Prevents gas issues with large registries by limiting return size
     * @param offset Starting index in the _registeredTokens array
     * @param limit Maximum number of tokens to return
     * @return tokens Array of registered token addresses
     * @return total Total number of registered tokens
     */
    function getRegisteredTokensPaginated(
        uint256 offset,
        uint256 limit
    ) external view returns (
        address[] memory tokens,
        uint256 total
    ) {
        total = _registeredTokens.length;
        // solhint-disable-next-line gas-strict-inequalities
        if (offset >= total) {
            return (new address[](0), total);
        }

        uint256 remaining = total - offset;
        uint256 count = remaining < limit ? remaining : limit;

        tokens = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            tokens[i] = _registeredTokens[offset + i];
        }
    }

    /**
     * @notice Get registered token count
     * @return Number of registered tokens
     */
    function getRegisteredTokenCount() external view returns (uint256) {
        return _registeredTokens.length;
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /* solhint-disable code-complexity */
    /**
     * @notice Internal compliance check logic (no cache read, no external call)
     * @dev Shared implementation used by checkCompliance (external),
     *      checkSwapCompliance, refreshCompliance, and batchCheckCompliance.
     *      Using an internal function avoids the ~700 gas overhead of
     *      external self-calls plus ABI encoding/decoding of the
     *      ComplianceResult struct (which contains a variable-length string).
     * @param user User address to check
     * @param token Token address to check
     * @return result Compliance result with status and details
     */
    /* solhint-disable not-rely-on-time, gas-small-strings */
    function _checkComplianceInternal(
        address user,
        address token
    ) internal view returns (ComplianceResult memory result) {
        // If token not registered, fail-closed: return NON_COMPLIANT.
        // All RWA tokens must be explicitly registered before trading.
        if (!_tokenConfigs[token].registered) {
            return ComplianceResult({
                status: ComplianceStatus.NON_COMPLIANT,
                tokenStandard: TokenStandard.UNKNOWN,
                kycRequired: false,
                accreditedInvestorRequired: false,
                holdingPeriodSeconds: 0,
                maxHolding: 0,
                reason: "Token not registered - compliance unknown",
                timestamp: block.timestamp,
                validUntil: block.timestamp + CACHE_TTL
            });
        }

        TokenConfig memory config = _tokenConfigs[token];

        // For ERC-20 tokens or disabled compliance, always compliant
        if (
            config.standard == TokenStandard.ERC20
            || !config.complianceEnabled
        ) {
            return ComplianceResult({
                status: ComplianceStatus.COMPLIANT,
                tokenStandard: config.standard,
                kycRequired: false,
                accreditedInvestorRequired: false,
                holdingPeriodSeconds: 0,
                maxHolding: 0,
                reason: "No compliance requirements",
                timestamp: block.timestamp,
                validUntil: block.timestamp + CACHE_TTL
            });
        }

        // Check compliance based on token standard
        if (config.standard == TokenStandard.ERC3643) {
            return _checkERC3643Compliance(user, token, config);
        } else if (config.standard == TokenStandard.ERC1400) {
            return _checkERC1400Compliance(user, token, config);
        }

        // Default: compliant (ERC-4626 and other standards)
        return ComplianceResult({
            status: ComplianceStatus.COMPLIANT,
            tokenStandard: config.standard,
            kycRequired: false,
            accreditedInvestorRequired: false,
            holdingPeriodSeconds: 0,
            maxHolding: 0,
            reason: "Standard compliance check passed",
            timestamp: block.timestamp,
            validUntil: block.timestamp + CACHE_TTL
        });
    }
    /* solhint-enable not-rely-on-time, gas-small-strings, code-complexity */

    /**
     * @notice Detect token standard via interface checks
     * @param token Token address
     * @return Detected token standard
     */
    function _detectTokenStandard(address token) internal view returns (TokenStandard) {
        // Try ERC-3643 check
        try IERC165(token).supportsInterface(ERC3643_INTERFACE) returns (bool supported) {
            if (supported) return TokenStandard.ERC3643;
        } catch {
            // Interface check not supported, continue
        }

        // Try ERC-1400 check
        try IERC165(token).supportsInterface(ERC1400_INTERFACE) returns (bool supported) {
            if (supported) return TokenStandard.ERC1400;
        } catch {
            // Interface check not supported, continue
        }

        // Probe for ERC-4626 vault via asset() function
        // (ERC-4626 has no ERC-165 ID; we call asset() directly)
        try IERC4626Probe(token).asset() returns (address) {
            return TokenStandard.ERC4626;
        } catch {
            // Not ERC-4626, continue
        }

        // Check for ERC-3643 canTransfer function
        try IERC3643(token).canTransfer(address(0), address(0), 0) returns (bool, bytes1, bytes32) {
            return TokenStandard.ERC3643;
        } catch {
            // Not ERC-3643
        }

        // Default to ERC-20
        return TokenStandard.ERC20;
    }

    /**
     * @notice Check ERC-3643 compliance via canTransfer call
     * @dev Uses canTransfer(user, oracleAddress, 1) instead of
     *      self-transfer (user, user, 1) because some T-REX
     *      implementations treat self-transfers as no-ops that
     *      bypass compliance checks.
     * @param user User address to check compliance for
     * @param config Token configuration with compliance contract address
     * @return Compliance result with status, reason, and cache timestamps
     */
    /* solhint-disable not-rely-on-time */
    function _checkERC3643Compliance(
        address user,
        address /* token */,
        TokenConfig memory config
    ) internal view returns (ComplianceResult memory) {
        address complianceAddr = config.complianceContract;

        // Call canTransfer with oracle as destination (not self-transfer)
        // to get a realistic compliance check. Self-transfers (from==to)
        // may be treated as no-ops in some T-REX implementations.
        try IERC3643(complianceAddr).canTransfer(
            user, address(this), 1
        ) returns (
            bool canTransfer,
            bytes1 /* reasonCode */,
            bytes32 /* messageId */
        ) {
            if (canTransfer) {
                return ComplianceResult({
                    status: ComplianceStatus.COMPLIANT,
                    tokenStandard: TokenStandard.ERC3643,
                    kycRequired: true,
                    accreditedInvestorRequired: false,
                    holdingPeriodSeconds: 0,
                    maxHolding: 0,
                    reason: "ERC-3643 compliance verified",
                    timestamp: block.timestamp,
                    validUntil: block.timestamp + CACHE_TTL
                });
            } else {
                return ComplianceResult({
                    status: ComplianceStatus.NON_COMPLIANT,
                    tokenStandard: TokenStandard.ERC3643,
                    kycRequired: true,
                    accreditedInvestorRequired: false,
                    holdingPeriodSeconds: 0,
                    maxHolding: 0,
                    reason: "ERC-3643 transfer not allowed",
                    timestamp: block.timestamp,
                    validUntil: block.timestamp + CACHE_TTL
                });
            }
        } catch {
            return ComplianceResult({
                status: ComplianceStatus.CHECK_FAILED,
                tokenStandard: TokenStandard.ERC3643,
                kycRequired: true,
                accreditedInvestorRequired: false,
                holdingPeriodSeconds: 0,
                maxHolding: 0,
                reason: "ERC-3643 compliance check failed",
                timestamp: block.timestamp,
                validUntil: block.timestamp + CACHE_TTL
            });
        }
    }
    /* solhint-enable not-rely-on-time */

    /**
     * @notice Check ERC-1400 compliance via canTransferByPartition call
     * @dev Uses bytes32("default") as the partition identifier, which is
     *      the standard convention for ERC-1400 tokens. Also checks the
     *      returned reasonCode: 0xA0-0xAF indicates success per ERC-1066.
     * @param user User address to check compliance for
     * @param config Token configuration with compliance contract address
     * @return Compliance result with status, reason, and cache timestamps
     */
    /* solhint-disable not-rely-on-time */
    function _checkERC1400Compliance(
        address user,
        address /* token */,
        TokenConfig memory config
    ) internal view returns (ComplianceResult memory) {
        address complianceAddr = config.complianceContract;

        // Use "default" partition (not bytes32(0) which many tokens reject)
        bytes32 defaultPartition = bytes32("default");

        try IERC1400(complianceAddr).canTransferByPartition(
            user,
            address(this),
            defaultPartition,
            1,
            ""
        ) returns (
            bytes1 reasonCode,
            bytes32 /* appCode */,
            bytes32 /* destPartition */
        ) {
            // Check reasonCode per ERC-1066:
            // 0xA0-0xAF = success range (strict: > 0x9F and < 0xB0)
            // Any other value = failure (even without revert)
            bool isSuccess = (reasonCode > 0x9F && reasonCode < 0xB0);

            if (isSuccess) {
                return ComplianceResult({
                    status: ComplianceStatus.COMPLIANT,
                    tokenStandard: TokenStandard.ERC1400,
                    kycRequired: true,
                    accreditedInvestorRequired: true,
                    holdingPeriodSeconds: 0,
                    maxHolding: 0,
                    reason: "ERC-1400 compliance verified",
                    timestamp: block.timestamp,
                    validUntil: block.timestamp + CACHE_TTL
                });
            } else {
                return ComplianceResult({
                    status: ComplianceStatus.NON_COMPLIANT,
                    tokenStandard: TokenStandard.ERC1400,
                    kycRequired: true,
                    accreditedInvestorRequired: true,
                    holdingPeriodSeconds: 0,
                    maxHolding: 0,
                    reason: "ERC-1400 transfer not allowed",
                    timestamp: block.timestamp,
                    validUntil: block.timestamp + CACHE_TTL
                });
            }
        } catch {
            return ComplianceResult({
                status: ComplianceStatus.CHECK_FAILED,
                tokenStandard: TokenStandard.ERC1400,
                kycRequired: true,
                accreditedInvestorRequired: true,
                holdingPeriodSeconds: 0,
                maxHolding: 0,
                reason: "ERC-1400 compliance check failed",
                timestamp: block.timestamp,
                validUntil: block.timestamp + CACHE_TTL
            });
        }
    }
    /* solhint-enable not-rely-on-time */
}

// ========================================================================
// HELPER INTERFACES
// ========================================================================

/* solhint-disable ordering */
/**
 * @title IERC165
 * @author OpenZeppelin
 * @notice ERC-165 interface detection
 */
interface IERC165 {
    /**
     * @notice Check if contract supports interface
     * @param interfaceId Interface identifier
     * @return True if interface is supported
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/**
 * @title IERC3643
 * @author T-REX (Tokeny)
 * @notice ERC-3643 T-REX security token interface
 */
interface IERC3643 {
    /**
     * @notice Check if transfer is allowed
     * @param from Source address
     * @param to Destination address
     * @param amount Transfer amount
     * @return canTransfer True if transfer is allowed
     * @return reasonCode Reason code
     * @return messageId Message identifier
     */
    function canTransfer(
        address from,
        address to,
        uint256 amount
    ) external view returns (bool canTransfer, bytes1 reasonCode, bytes32 messageId);
}

/**
 * @title IERC1400
 * @author Polymath
 * @notice ERC-1400 security token interface
 */
interface IERC1400 {
    /**
     * @notice Check if partition transfer is allowed
     * @param from Source address
     * @param to Destination address
     * @param partition Partition identifier
     * @param amount Transfer amount
     * @param data Additional data
     * @return reasonCode Reason code
     * @return appCode Application code
     * @return destPartition Destination partition
     */
    function canTransferByPartition(
        address from,
        address to,
        bytes32 partition,
        uint256 amount,
        bytes calldata data
    ) external view returns (bytes1 reasonCode, bytes32 appCode, bytes32 destPartition);
}

/**
 * @title IERC4626Probe
 * @author OmniCoin Development Team
 * @notice Minimal interface for probing ERC-4626 vault contracts
 * @dev Used to detect ERC-4626 vaults by calling asset()
 */
interface IERC4626Probe {
    /**
     * @notice Get the underlying asset address
     * @return Underlying token address
     */
    function asset() external view returns (address);
}
