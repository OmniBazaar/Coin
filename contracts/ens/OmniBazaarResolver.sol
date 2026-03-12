// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ECDSA} from
    "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable2Step, Ownable} from
    "@openzeppelin/contracts/access/Ownable2Step.sol";

// ======================================================================
//                           CUSTOM ERRORS
// ======================================================================

/// @notice ERC-3668 OffchainLookup revert — triggers CCIP-Read in the client
/// @param sender The resolver contract address
/// @param urls Gateway URL templates with {sender} and {data} placeholders
/// @param callData ABI-encoded (dnsName, resolverCalldata)
/// @param callbackFunction Selector of the callback (resolveWithProof)
/// @param extraData Opaque bytes forwarded to the callback
error OffchainLookup(
    address sender,
    string[] urls,
    bytes callData,
    bytes4 callbackFunction,
    bytes extraData
);

/// @notice Gateway response signature does not match the trusted signer
error InvalidSignature();

/// @notice Gateway response has expired (block.timestamp > expires)
error ResponseExpired();

/// @notice Constructor or setter received an empty gateway URL array
error NoGatewayURLs();

/// @notice Constructor or setter received the zero address as signer
error ZeroSigner();

// ======================================================================
//                       OmniBazaarResolver
// ======================================================================

/// @title OmniBazaarResolver — ENSIP-10 Wildcard Resolver with ERC-3668 CCIP-Read
/// @author OmniBazaar Team
/// @notice Resolves *.omnibazaar.eth names by redirecting clients to an off-chain
///         CCIP-Read gateway that reads OmniENS on Avalanche Subnet-EVM. The gateway
///         response is verified on-chain via ECDSA signature before returning data.
/// @dev Deploy on Ethereum mainnet. Set as the resolver for the `omnibazaar.eth`
///      ENS node via the ENS Registry `setResolver(node, address)` call.
///      The contract stores zero name-to-address mappings; all resolution data
///      originates from the gateway and is verified by signature.
contract OmniBazaarResolver is Ownable2Step {
    using ECDSA for bytes32;

    // -- State Variables --

    /// @notice Gateway URL template (with {sender} and {data} placeholders)
    /// @dev Example: "https://ens-gateway.omnibazaar.com/ccip/{sender}/{data}.json"
    string[] public gatewayURLs;

    /// @notice Address authorized to sign gateway responses
    address public signer;

    /// @notice Response TTL in seconds (default: 300 = 5 minutes)
    uint256 public responseTTL;

    // -- Events --

    /// @notice Emitted when the gateway URLs are updated
    /// @param newURLs The new gateway URL templates
    event GatewayURLsUpdated(string[] newURLs);

    /// @notice Emitted when the signer address is updated
    /// @param oldSigner The previous signer address
    /// @param newSigner The new signer address
    event SignerUpdated(
        address indexed oldSigner,
        address indexed newSigner
    );

    /// @notice Emitted when the response TTL is updated
    /// @param oldTTL The previous TTL in seconds
    /// @param newTTL The new TTL in seconds
    event ResponseTTLUpdated(uint256 indexed oldTTL, uint256 indexed newTTL);

    // -- Constructor --

    /// @notice Deploy the resolver with initial gateway configuration
    /// @param _gatewayURLs Initial gateway URL templates (must not be empty)
    /// @param _signer Initial authorized signer address (must not be zero)
    /// @param _responseTTL Response validity window in seconds
    constructor(
        string[] memory _gatewayURLs,
        address _signer,
        uint256 _responseTTL
    ) Ownable(msg.sender) {
        if (_gatewayURLs.length == 0) revert NoGatewayURLs();
        if (_signer == address(0)) revert ZeroSigner();

        gatewayURLs = _gatewayURLs;
        signer = _signer;
        responseTTL = _responseTTL;
    }

    // -- External (Mutating) Functions --

    /// @notice Update gateway URLs
    /// @param _gatewayURLs New gateway URL templates (must not be empty)
    function setGatewayURLs(
        string[] calldata _gatewayURLs
    ) external onlyOwner {
        if (_gatewayURLs.length == 0) revert NoGatewayURLs();
        gatewayURLs = _gatewayURLs;
        emit GatewayURLsUpdated(_gatewayURLs);
    }

    /// @notice Update the authorized signer address
    /// @param _signer New signer address (must not be zero)
    function setSigner(address _signer) external onlyOwner {
        if (_signer == address(0)) revert ZeroSigner();
        address oldSigner = signer;
        signer = _signer;
        emit SignerUpdated(oldSigner, _signer);
    }

    /// @notice Update the response TTL
    /// @param _responseTTL New TTL in seconds
    function setResponseTTL(uint256 _responseTTL) external onlyOwner {
        uint256 oldTTL = responseTTL;
        responseTTL = _responseTTL;
        emit ResponseTTLUpdated(oldTTL, _responseTTL);
    }

    // -- External View Functions --

    /// @notice Implements ENSIP-10 resolve(bytes, bytes)
    /// @dev Called by the ENS Universal Resolver for *.omnibazaar.eth lookups.
    ///      Always reverts with OffchainLookup to trigger CCIP-Read in the client.
    /// @param name DNS-encoded name (e.g., "\x05alice\x0aomnibazaar\x03eth\x00")
    /// @param data ABI-encoded resolver call (e.g., addr(bytes32) or text(bytes32,string))
    /// @return This function never returns — it always reverts with OffchainLookup
    function resolve(
        bytes calldata name,
        bytes calldata data
    ) external view returns (bytes memory) {
        bytes memory callData = abi.encode(name, data);
        revert OffchainLookup(
            address(this),
            gatewayURLs,
            callData,
            this.resolveWithProof.selector,
            callData // extraData = callData for verification
        );
    }

    /// @notice Callback invoked by the ENS client after fetching the gateway response
    /// @dev Verifies the ECDSA signature from the gateway, checks TTL, and returns
    ///      the resolved data. The signed payload is:
    ///      keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32",
    ///          keccak256(abi.encodePacked(result, expires, extraData))))
    /// @param response ABI-encoded gateway response: (bytes result, uint64 expires, bytes signature)
    /// @param extraData Original callData passed through for context verification
    /// @return The ABI-encoded resolver response (address, text, etc.)
    function resolveWithProof(
        bytes calldata response,
        bytes calldata extraData
    ) external view returns (bytes memory) {
        (bytes memory result, uint64 expires, bytes memory sig) =
            abi.decode(response, (bytes, uint64, bytes));

        // Check TTL — time-based check is required for response freshness
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > expires) revert ResponseExpired();

        // Reconstruct the signed message (EIP-191 personal sign)
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encodePacked(result, expires, extraData)
                )
            )
        );

        // Verify signature
        address recovered = ECDSA.recover(messageHash, sig);
        if (recovered != signer) revert InvalidSignature();

        return result;
    }

    /// @notice Get all gateway URLs
    /// @return The current gateway URL list
    function getGatewayURLs()
        external
        view
        returns (string[] memory)
    {
        return gatewayURLs;
    }

    // -- External Pure Functions --

    /// @notice Reports supported interfaces
    /// @dev Returns true for ENSIP-10 resolve(bytes,bytes) and ERC-165
    /// @param interfaceId The interface identifier to check
    /// @return True if the interface is supported
    function supportsInterface(
        bytes4 interfaceId
    ) external pure returns (bool) {
        return
            interfaceId == 0x9061b923 || // ENSIP-10 resolve(bytes,bytes)
            interfaceId == 0x01ffc9a7; // ERC-165
    }
}
