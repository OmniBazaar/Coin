// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ECDSA} from
    "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable2Step, Ownable} from
    "@openzeppelin/contracts/access/Ownable2Step.sol";

/* solhint-disable gas-strict-inequalities */
// gas-strict-inequalities: `<=` semantics are required for the sorted-unique
// signer dedup checks (`recovered <= last` / `s <= prev`) — a strict `<` would
// accept duplicate signers. Same justification as `RandomCommitteeVerifierV2.sol`
// and the verbatim-reused v1 `RandomCommitteeVerifier.sol`.

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

/// @notice Gateway response signature does not match the required threshold
///         of authorized signers
error InvalidSignature();

/// @notice Gateway response has expired (block.timestamp > expires)
error ResponseExpired();

/// @notice Constructor or setter received an empty gateway URL array
error NoGatewayURLs();
/// @dev Thrown when a gateway URL is empty or not https-prefixed.
error InvalidGatewayURL();

/// @notice The signer set is empty or contains the zero address
error ZeroSigner();

/// @notice The signer set is not strictly ascending (duplicate or unsorted)
error InvalidSignerOrder();

/// @notice `requiredSignatures` is zero or exceeds the signer-set length
error RequiredSignaturesOutOfRange();

/// @notice Response TTL exceeds the maximum allowed window
error ResponseTTLTooLong();

// ======================================================================
//                       OmniBazaarResolver
// ======================================================================

/// @title OmniBazaarResolver — ENSIP-10 Wildcard Resolver with ERC-3668 CCIP-Read
/// @author OmniBazaar Team
/// @notice Resolves *.omnibazaar.eth names by redirecting clients to an off-chain
///         CCIP-Read gateway that reads OmniENS on Avalanche Subnet-EVM. The gateway
///         response is verified on-chain via an M-of-N ECDSA threshold signature
///         before returning data, so no single gateway operator (or shared signer
///         key) can fabricate a name→address binding on its own.
/// @dev Deploy on Ethereum mainnet. Set as the resolver for the `omnibazaar.eth`
///      ENS node via the ENS Registry `setResolver(node, address)` call.
///      The contract stores zero name-to-address mappings; all resolution data
///      originates from the gateway and is verified by an M-of-N signature.
contract OmniBazaarResolver is Ownable2Step {
    using ECDSA for bytes32;

    /// @notice Length of one canonical ECDSA signature (r || s || v).
    uint256 public constant SIGNATURE_LENGTH = 65;

    /// @notice Maximum response TTL (365 days). Bounds `block.timestamp +
    ///         responseTTL` so the expiry check can never overflow.
    uint256 public constant MAX_RESPONSE_TTL = 365 days;

    // -- State Variables --

    /// @notice Gateway URL template (with {sender} and {data} placeholders)
    /// @dev Example: "https://ens-gateway.omnibazaar.com/ccip/{sender}/{data}.json"
    string[] public gatewayURLs;

    /// @notice Addresses authorized to sign gateway responses, sorted ascending
    ///         (one per gateway validator). A response is accepted only when it
    ///         carries at least `requiredSignatures` distinct signatures from
    ///         this set.
    address[] public signers;

    /// @notice Minimum number of distinct signer signatures required to accept
    ///         a response. Must be in [1, signers.length].
    uint256 public requiredSignatures;

    /// @notice Response TTL in seconds (default: 300 = 5 minutes)
    uint256 public responseTTL;

    /// @notice O(1) membership lookup for the current signer set.
    mapping(address signer => bool isSigner) private _isSigner;

    // -- Events --

    /// @notice Emitted when the gateway URLs are updated
    /// @param newURLs The new gateway URL templates
    event GatewayURLsUpdated(string[] newURLs);

    /// @notice Emitted when the signer set / threshold is updated
    /// @param newSigners The new signer address set (sorted ascending)
    /// @param newRequiredSignatures The new minimum signature count
    event SignersUpdated(
        address[] newSigners,
        uint256 newRequiredSignatures
    );

    /// @notice Emitted when the response TTL is updated
    /// @param oldTTL The previous TTL in seconds
    /// @param newTTL The new TTL in seconds
    event ResponseTTLUpdated(uint256 indexed oldTTL, uint256 indexed newTTL);

    // -- Constructor --

    /// @notice Deploy the resolver with initial gateway configuration
    /// @param _gatewayURLs Initial gateway URL templates (must not be empty)
    /// @param _signers Initial authorized signer addresses, sorted ascending,
    ///        non-zero (must not be empty)
    /// @param _requiredSignatures Minimum distinct signatures required
    ///        (must be in [1, _signers.length])
    /// @param _responseTTL Response validity window in seconds
    constructor(
        string[] memory _gatewayURLs,
        address[] memory _signers,
        uint256 _requiredSignatures,
        uint256 _responseTTL
    ) Ownable(msg.sender) {
        if (_gatewayURLs.length == 0) revert NoGatewayURLs();
        if (_responseTTL > MAX_RESPONSE_TTL) revert ResponseTTLTooLong();
        _validateGatewayURLs(_gatewayURLs);
        _validateSignerSet(_signers, _requiredSignatures);

        gatewayURLs = _gatewayURLs;
        _setSigners(_signers, _requiredSignatures);
        responseTTL = _responseTTL;
    }

    // -- External (Mutating) Functions --

    /// @notice Update gateway URLs
    /// @param _gatewayURLs New gateway URL templates (must not be empty)
    function setGatewayURLs(
        string[] calldata _gatewayURLs
    ) external onlyOwner {
        if (_gatewayURLs.length == 0) revert NoGatewayURLs();
        _validateGatewayURLs(_gatewayURLs);
        gatewayURLs = _gatewayURLs;
        emit GatewayURLsUpdated(_gatewayURLs);
    }

    /// @notice Update the authorized signer set and threshold
    /// @param _signers New signer addresses, sorted ascending, non-zero
    /// @param _requiredSignatures New minimum distinct signature count
    ///        (must be in [1, _signers.length])
    function setSigners(
        address[] calldata _signers,
        uint256 _requiredSignatures
    ) external onlyOwner {
        _validateSignerSet(_signers, _requiredSignatures);
        _setSigners(_signers, _requiredSignatures);
        emit SignersUpdated(_signers, _requiredSignatures);
    }

    /// @notice Update the response TTL
    /// @param _responseTTL New TTL in seconds
    function setResponseTTL(uint256 _responseTTL) external onlyOwner {
        if (_responseTTL > MAX_RESPONSE_TTL) revert ResponseTTLTooLong();
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
    /// @dev Verifies an M-of-N ECDSA threshold signature from the gateway
    ///      signer set, checks TTL, and returns the resolved data. The signed
    ///      payload is:
    ///      keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32",
    ///          keccak256(abi.encode(block.chainid, address(this), result,
    ///          expires, extraData))))
    ///      The digest binds the response to THIS chain and THIS resolver, so
    ///      a signature cannot be replayed across chains (or resolvers) under
    ///      a reused signer key. The gateway signs with the identical
    ///      abi.encode(uint256 chainid, address resolver, bytes result,
    ///      uint64 expires, bytes extraData).
    /// @param response ABI-encoded gateway response: (bytes result, uint64 expires, bytes signatures)
    ///        where `signatures` is the concatenation of `requiredSignatures`+
    ///        65-byte ECDSA signatures, ordered by ascending recovered signer.
    /// @param extraData Original callData passed through for context verification
    /// @return The ABI-encoded resolver response (address, text, etc.)
    function resolveWithProof(
        bytes calldata response,
        bytes calldata extraData
    ) external view returns (bytes memory) {
        (bytes memory result, uint64 expires, bytes memory sigs) =
            abi.decode(response, (bytes, uint64, bytes));

        // Check TTL — time-based check is required for response freshness
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > expires) revert ResponseExpired();

        // ECO-03: enforce `responseTTL` as an on-chain ceiling so a
        // compromised or misconfigured gateway cannot mint effectively
        // permanent responses by setting an arbitrarily far `expires`.
        // solhint-disable-next-line not-rely-on-time
        if (expires > block.timestamp + responseTTL) revert ResponseExpired();

        // Reconstruct the signed message (EIP-191 personal sign). The digest
        // binds the response to this chain and this resolver contract via
        // block.chainid + address(this), so a signature produced for a
        // different chain (or a different resolver address) recovers to the
        // wrong signer and is rejected below. Encoding:
        // keccak256(abi.encode(block.chainid, address(this), result, expires,
        // extraData)) — MUST mirror CCIPReadGateway.signResponse exactly.
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encode(
                        block.chainid,
                        address(this),
                        result,
                        expires,
                        extraData
                    )
                )
            )
        );

        _verifyThresholdSignatures(messageHash, sigs);

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

    /// @notice Get the current signer set (sorted ascending)
    /// @return The authorized signer addresses
    function getSigners() external view returns (address[] memory) {
        return signers;
    }

    /// @notice Report whether `account` is in the current signer set
    /// @param account Address to test
    /// @return True if `account` is an authorized signer
    function isSigner(address account) external view returns (bool) {
        return _isSigner[account];
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

    // -- Internal Functions --

    /// @dev Write a validated signer set into storage (clears the prior set).
    function _setSigners(
        address[] memory _signers,
        uint256 _requiredSignatures
    ) internal {
        uint256 oldLen = signers.length;
        for (uint256 i; i < oldLen; ++i) {
            _isSigner[signers[i]] = false;
        }
        delete signers;

        uint256 len = _signers.length;
        for (uint256 i; i < len; ++i) {
            address s = _signers[i];
            signers.push(s);
            _isSigner[s] = true;
        }
        requiredSignatures = _requiredSignatures;
    }

    /// @dev Gateway URLs are served to clients in OffchainLookup reverts;
    ///      require a well-formed https:// prefix so a typo or downgrade
    ///      cannot break or insecurely redirect CCIP-Read resolution.
    function _validateGatewayURLs(string[] memory urls) internal pure {
        for (uint256 i; i < urls.length; ++i) {
            bytes memory b = bytes(urls[i]);
            bool ok = b.length >= 8
                && b[0] == "h" && b[1] == "t" && b[2] == "t" && b[3] == "p"
                && b[4] == "s" && b[5] == ":" && b[6] == "/" && b[7] == "/";
            if (!ok) revert InvalidGatewayURL();
        }
    }

    /// @dev Validate a candidate signer set: non-empty, no zero address,
    ///      strictly ascending (which also enforces uniqueness), and a
    ///      threshold in [1, length]. Mirrors the committee verifier's
    ///      sorted-unique assumption so signature dedup is well-defined.
    function _validateSignerSet(
        address[] memory _signers,
        uint256 _requiredSignatures
    ) internal pure {
        uint256 len = _signers.length;
        if (len == 0) revert ZeroSigner();
        if (_requiredSignatures == 0 || _requiredSignatures > len) {
            revert RequiredSignaturesOutOfRange();
        }
        address prev;
        for (uint256 i; i < len; ++i) {
            address s = _signers[i];
            if (s == address(0)) revert ZeroSigner();
            if (s <= prev) revert InvalidSignerOrder();
            prev = s;
        }
    }

    // -- Private Functions --

    /// @dev Recover and validate every signature in `sigs` against the signed
    ///      digest. Requires: a whole number of 65-byte signatures, at least
    ///      `requiredSignatures` of them, recovered signers sorted ascending
    ///      (dedup) and all members of the signer set. Reverts
    ///      `InvalidSignature` on any violation.
    function _verifyThresholdSignatures(
        bytes32 messageHash,
        bytes memory sigs
    ) private view {
        uint256 sigCount = sigs.length / SIGNATURE_LENGTH;
        if (
            sigs.length == 0 ||
            sigs.length % SIGNATURE_LENGTH != 0 ||
            sigCount < requiredSignatures
        ) {
            revert InvalidSignature();
        }

        address last;
        for (uint256 i = 0; i < sigCount; ) {
            bytes memory sig = _sliceSignature(sigs, i);
            (address recovered, ECDSA.RecoverError err, ) =
                messageHash.tryRecover(sig);
            if (err != ECDSA.RecoverError.NoError || recovered == address(0)) {
                revert InvalidSignature();
            }
            if (recovered <= last) revert InvalidSignature();
            if (!_isSigner[recovered]) revert InvalidSignature();
            last = recovered;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Copy the i-th 65-byte signature out of the concatenated blob.
    function _sliceSignature(
        bytes memory sigs,
        uint256 i
    ) private pure returns (bytes memory sig) {
        sig = new bytes(SIGNATURE_LENGTH);
        uint256 offset = i * SIGNATURE_LENGTH;
        for (uint256 j = 0; j < SIGNATURE_LENGTH; ) {
            sig[j] = sigs[offset + j];
            unchecked {
                ++j;
            }
        }
    }
}
