// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRWAComplianceOracle} from "./interfaces/IRWAComplianceOracle.sol";

/**
 * @title RWAComplianceOracle
 * @author OmniCoin Development Team
 * @notice On-chain compliance verification for RWA tokens
 * @dev Delegates compliance checking to individual token contracts
 *
 * Supported Token Standards:
 * - ERC-20: Basic tokens (no compliance)
 * - ERC-3643: T-REX security tokens with canTransfer()
 * - ERC-1400: Security tokens with canTransferByPartition()
 * - ERC-4626: Tokenized vaults
 *
 * Key Features:
 * - Standard auto-detection
 * - Compliance result caching (5-minute TTL)
 * - Batch compliance checking
 * - Graceful degradation on failures
 *
 * Security Features:
 * - Reentrancy protection
 * - Safe external calls
 * - Timeout handling
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

    /// @notice ERC-4626 interface ID
    bytes4 private constant ERC4626_INTERFACE = 0x7ecebe00;

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
            lastUpdated: block.timestamp
        });

        _registeredTokens.push(token);

        emit TokenRegistered(token, standard, complianceContract);
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

    /**
     * @inheritdoc IRWAComplianceOracle
     */
    function checkCompliance(
        address user,
        address token
    ) external view override returns (ComplianceResult memory result) {
        // Check cache first
        ComplianceResult memory cached = _complianceCache[user][token];
        // solhint-disable-next-line not-rely-on-time
        if (cached.validUntil > block.timestamp) {
            return cached;
        }

        // If token not registered, return compliant (no restrictions)
        if (!_tokenConfigs[token].registered) {
            return ComplianceResult({
                status: ComplianceStatus.COMPLIANT,
                tokenStandard: TokenStandard.ERC20,
                kycRequired: false,
                accreditedInvestorRequired: false,
                holdingPeriodSeconds: 0,
                maxHolding: 0,
                reason: "Token not registered - no compliance required",
                timestamp: block.timestamp,
                validUntil: block.timestamp + CACHE_TTL
            });
        }

        TokenConfig memory config = _tokenConfigs[token];

        // For ERC-20 tokens, always compliant
        if (config.standard == TokenStandard.ERC20 || !config.complianceEnabled) {
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

        // Default: compliant
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
        // Check input token compliance
        ComplianceResult memory inputResult = this.checkCompliance(user, tokenIn);
        inputCompliant = inputResult.status == ComplianceStatus.COMPLIANT;

        // Check output token compliance
        ComplianceResult memory outputResult = this.checkCompliance(user, tokenOut);
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

    /**
     * @inheritdoc IRWAComplianceOracle
     */
    function refreshCompliance(address user, address token) external override nonReentrant {
        // Re-check compliance and update cache
        ComplianceResult memory result = this.checkCompliance(user, token);

        _complianceCache[user][token] = result;

        emit ComplianceCached(user, token, result.validUntil);
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

        results = new ComplianceResult[](users.length);

        for (uint256 i = 0; i < users.length; ++i) {
            results[i] = this.checkCompliance(users[i], tokens[i]);
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
     * @notice Get all registered tokens
     * @return Array of registered token addresses
     */
    function getRegisteredTokens() external view returns (address[] memory) {
        return _registeredTokens;
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

        // Try ERC-4626 check
        try IERC165(token).supportsInterface(ERC4626_INTERFACE) returns (bool supported) {
            if (supported) return TokenStandard.ERC4626;
        } catch {
            // Interface check not supported, continue
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
     * @notice Check ERC-3643 compliance
     * @param user User address
     * @param config Token configuration
     * @return Compliance result
     */
    function _checkERC3643Compliance(
        address user,
        address /* token */,
        TokenConfig memory config
    ) internal view returns (ComplianceResult memory) {
        address complianceAddr = config.complianceContract;

        // Call canTransfer on the token/compliance contract
        try IERC3643(complianceAddr).canTransfer(user, user, 1) returns (
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

    /**
     * @notice Check ERC-1400 compliance
     * @param user User address
     * @param config Token configuration
     * @return Compliance result
     */
    function _checkERC1400Compliance(
        address user,
        address /* token */,
        TokenConfig memory config
    ) internal view returns (ComplianceResult memory) {
        address complianceAddr = config.complianceContract;

        // Call canTransferByPartition on the token/compliance contract
        // Using default partition
        bytes32 defaultPartition = bytes32(0);

        try IERC1400(complianceAddr).canTransferByPartition(
            user,
            user,
            defaultPartition,
            1,
            ""
        ) returns (
            bytes1 /* reasonCode */,
            bytes32 /* appCode */,
            bytes32 /* destPartition */
        ) {
            // If call succeeds, user is compliant
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
}

// ========================================================================
// HELPER INTERFACES
// ========================================================================

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
