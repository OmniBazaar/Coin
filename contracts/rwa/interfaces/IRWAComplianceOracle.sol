// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRWAComplianceOracle
 * @author OmniCoin Development Team
 * @notice Interface for on-chain RWA compliance checking
 * @dev Delegates compliance verification to individual token contracts
 */
interface IRWAComplianceOracle {
    // ========================================================================
    // ENUMS
    // ========================================================================

    /// @notice Token standard types for compliance checking
    enum TokenStandard {
        ERC20,
        ERC3643,
        ERC1400,
        ERC4626,
        UNKNOWN
    }

    /// @notice Compliance check result status
    enum ComplianceStatus {
        COMPLIANT,
        NON_COMPLIANT,
        PENDING_VERIFICATION,
        CHECK_FAILED
    }

    // ========================================================================
    // STRUCTS
    // ========================================================================

    /**
     * @notice Compliance check result structure
     * @dev Contains detailed compliance information
     */
    struct ComplianceResult {
        ComplianceStatus status;
        TokenStandard tokenStandard;
        bool kycRequired;
        bool accreditedInvestorRequired;
        uint256 holdingPeriodSeconds;
        uint256 maxHolding;
        string reason;
        uint256 timestamp;
        uint256 validUntil;
    }

    /**
     * @notice Token compliance configuration
     * @dev Cached configuration for each token
     */
    struct TokenConfig {
        TokenStandard standard;
        bool registered;
        bool complianceEnabled;
        address complianceContract;
        uint256 lastUpdated;
    }

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when compliance check is performed
    /// @param user User address
    /// @param token Token address
    /// @param status Compliance status
    /// @param reason Reason for status
    event ComplianceChecked(
        address indexed user,
        address indexed token,
        ComplianceStatus status,
        string reason
    );

    /// @notice Emitted when token is registered
    /// @param token Token address
    /// @param standard Token standard
    /// @param complianceContract Compliance contract address
    event TokenRegistered(
        address indexed token,
        TokenStandard standard,
        address complianceContract
    );

    /// @notice Emitted when compliance cache is updated
    /// @param user User address
    /// @param token Token address
    /// @param validUntil Cache expiry timestamp
    event ComplianceCached(
        address indexed user,
        address indexed token,
        uint256 validUntil
    );

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Thrown when token is not registered
    /// @param token Token address
    error TokenNotRegistered(address token);

    /// @notice Thrown when compliance check times out
    /// @param token Token address
    error ComplianceCheckTimeout(address token);

    /// @notice Thrown when compliance contract call fails
    /// @param token Token address
    /// @param reason Failure reason
    error ComplianceCallFailed(address token, string reason);

    /// @notice Thrown when user is not compliant
    /// @param user User address
    /// @param token Token address
    /// @param reason Non-compliance reason
    error UserNotCompliant(address user, address token, string reason);

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /**
     * @notice Check if user is compliant for token
     * @param user User address
     * @param token Token address
     * @return result Compliance result
     */
    function checkCompliance(
        address user,
        address token
    ) external view returns (ComplianceResult memory result);

    /**
     * @notice Check if swap is compliant
     * @param user User address
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input amount
     * @return inputCompliant Input token compliance
     * @return outputCompliant Output token compliance
     * @return reason Combined reason if non-compliant
     */
    function checkSwapCompliance(
        address user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (
        bool inputCompliant,
        bool outputCompliant,
        string memory reason
    );

    /**
     * @notice Get token configuration
     * @param token Token address
     * @return config Token configuration
     */
    function getTokenConfig(
        address token
    ) external view returns (TokenConfig memory config);

    /**
     * @notice Check if token is registered
     * @param token Token address
     * @return registered True if registered
     */
    function isTokenRegistered(address token) external view returns (bool registered);

    /**
     * @notice Detect token standard
     * @param token Token address
     * @return standard Detected token standard
     */
    function detectTokenStandard(address token) external view returns (TokenStandard standard);

    /**
     * @notice Get compliance cache TTL
     * @return ttl Cache time-to-live in seconds
     */
    function complianceCacheTTL() external view returns (uint256 ttl);

    // ========================================================================
    // STATE-CHANGING FUNCTIONS
    // ========================================================================

    /**
     * @notice Register token for compliance checking
     * @param token Token address
     * @param complianceContract Optional external compliance contract
     */
    function registerToken(
        address token,
        address complianceContract
    ) external;

    /**
     * @notice Update compliance cache for user/token pair
     * @param user User address
     * @param token Token address
     */
    function refreshCompliance(address user, address token) external;

    /**
     * @notice Batch check compliance for multiple users/tokens
     * @param users Array of user addresses
     * @param tokens Array of token addresses
     * @return results Array of compliance results
     */
    function batchCheckCompliance(
        address[] calldata users,
        address[] calldata tokens
    ) external view returns (ComplianceResult[] memory results);
}
