// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EIP712Upgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from
    "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// ══════════════════════════════════════════════════════════════════════
//                           CUSTOM ERRORS
// ══════════════════════════════════════════════════════════════════════

/// @notice Zero address provided
error ZeroAddress();

/// @notice Invalid IPFS CID (zero bytes)
error InvalidIPFSCID();

/// @notice Invalid content hash (zero bytes)
error InvalidContentHash();

/// @notice Invalid price (zero)
error ZeroPrice();

/// @notice Listing does not exist
error ListingNotFound(uint256 listingId);

/// @notice Caller is not the listing creator
error NotListingCreator();

/// @notice Listing has expired
error ListingExpired(uint256 listingId);

/// @notice Invalid signature
error InvalidSignature();

/// @notice Listing already exists with this CID
error DuplicateListing(bytes32 ipfsCID);

/// @notice Expiry too far in the future
error ExpiryTooFar(uint256 maxExpiry);

/**
 * @title OmniMarketplace
 * @author OmniBazaar Team
 * @notice On-chain registry for marketplace listings ensuring content
 *         integrity and tamper-proof provenance
 *
 * @dev Stores ONLY listing hashes on-chain (no content). All actual
 *      content is on IPFS. This contract provides:
 *      - Creator signature verification (EIP-712)
 *      - Content hash integrity checking
 *      - Tamper-proof listing registry
 *      - Expiry management (default 60 days)
 *      - Per-creator listing count (for participation scoring)
 *
 * Architecture:
 * - Creator signs listing data with EIP-712 before submission
 * - Validator relays the signed transaction but cannot forge listings
 * - Anyone can verify content matches on-chain hash
 * - Only creator can delist (validators cannot censor)
 * - Lightweight: ~200 bytes storage per listing
 *
 * Security:
 * - UUPS upgradeable, Pausable, ReentrancyGuard
 * - EIP-712 signatures prevent validator forgery
 * - Content hash prevents post-creation tampering
 * - Only creator can modify/delist their own listings
 */
contract OmniMarketplace is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    EIP712Upgradeable
{
    // ══════════════════════════════════════════════════════════════════
    //                        TYPE DECLARATIONS
    // ══════════════════════════════════════════════════════════════════

    /// @notice On-chain listing record
    struct Listing {
        address creator;
        bytes32 ipfsCID;
        bytes32 contentHash;
        uint256 price;
        uint256 expiry;
        uint256 createdAt;
        bool active;
    }

    // ══════════════════════════════════════════════════════════════════
    //                            CONSTANTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice EIP-712 typehash for listing registration
    bytes32 public constant LISTING_TYPEHASH = keccak256(
        "Listing(bytes32 ipfsCID,bytes32 contentHash,uint256 price,"
        "uint256 expiry,uint256 nonce)"
    );

    /// @notice Role for marketplace configuration
    bytes32 public constant MARKETPLACE_ADMIN_ROLE =
        keccak256("MARKETPLACE_ADMIN_ROLE");

    /// @notice Maximum expiry duration (365 days)
    uint256 public constant MAX_EXPIRY_DURATION = 365 days;

    // ══════════════════════════════════════════════════════════════════
    //                          STATE VARIABLES
    // ══════════════════════════════════════════════════════════════════

    /// @notice Next listing ID
    uint256 public nextListingId;

    /// @notice All listings by ID
    mapping(uint256 => Listing) public listings;

    /// @notice Per-creator listing count (active)
    mapping(address => uint256) public listingCount;

    /// @notice Per-creator total listings ever created
    mapping(address => uint256) public totalListingsCreated;

    /// @notice Nonce per creator for replay protection
    mapping(address => uint256) public nonces;

    /// @notice CID to listing ID mapping (deduplication)
    mapping(bytes32 => uint256) public cidToListingId;

    /// @notice Default expiry duration (60 days)
    uint256 public defaultExpiry;

    // ══════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Emitted when a listing is registered on-chain
    event ListingRegistered(
        uint256 indexed listingId,
        address indexed creator,
        bytes32 ipfsCID,
        bytes32 contentHash,
        uint256 price,
        uint256 expiry
    );

    /// @notice Emitted when a listing is delisted by creator
    event ListingDelisted(
        uint256 indexed listingId,
        address indexed creator
    );

    /// @notice Emitted when a listing is renewed
    event ListingRenewed(
        uint256 indexed listingId,
        uint256 newExpiry
    );

    /// @notice Emitted when listing price is updated
    event ListingPriceUpdated(
        uint256 indexed listingId,
        uint256 oldPrice,
        uint256 newPrice
    );

    // ══════════════════════════════════════════════════════════════════
    //                           INITIALIZER
    // ══════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the marketplace registry
     */
    function initialize() external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __EIP712_init("OmniMarketplace", "1");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MARKETPLACE_ADMIN_ROLE, msg.sender);

        nextListingId = 1;
        defaultExpiry = 60 days;
    }

    // ══════════════════════════════════════════════════════════════════
    //                     LISTING REGISTRATION
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Register a listing with creator's EIP-712 signature
     * @dev Validator relays this transaction but cannot forge the
     *      listing because only the creator holds the signing key.
     * @param ipfsCID IPFS content identifier
     * @param contentHash Keccak256 hash of listing content
     * @param price Listing price in XOM (18 decimals)
     * @param expiry Expiry timestamp (0 = use default)
     * @param signature Creator's EIP-712 signature
     */
    function registerListing(
        bytes32 ipfsCID,
        bytes32 contentHash,
        uint256 price,
        uint256 expiry,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        if (ipfsCID == bytes32(0)) revert InvalidIPFSCID();
        if (contentHash == bytes32(0)) revert InvalidContentHash();
        if (price == 0) revert ZeroPrice();
        if (cidToListingId[ipfsCID] != 0) {
            revert DuplicateListing(ipfsCID);
        }

        // Default expiry if not specified
        if (expiry == 0) {
            // solhint-disable-next-line not-rely-on-time
            expiry = block.timestamp + defaultExpiry;
        }

        // Cap expiry
        // solhint-disable-next-line not-rely-on-time
        if (expiry > block.timestamp + MAX_EXPIRY_DURATION) {
            revert ExpiryTooFar(
                block.timestamp + MAX_EXPIRY_DURATION // solhint-disable-line not-rely-on-time
            );
        }

        // Get creator nonce for replay protection
        uint256 nonce = nonces[msg.sender];

        // Verify EIP-712 signature
        bytes32 structHash = keccak256(
            abi.encode(
                LISTING_TYPEHASH,
                ipfsCID,
                contentHash,
                price,
                expiry,
                nonce
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);

        if (signer != msg.sender) revert InvalidSignature();

        // Increment nonce
        nonces[msg.sender] = nonce + 1;

        // Create listing
        uint256 listingId = nextListingId++;

        listings[listingId] = Listing({
            creator: msg.sender,
            ipfsCID: ipfsCID,
            contentHash: contentHash,
            price: price,
            expiry: expiry,
            createdAt: block.timestamp, // solhint-disable-line not-rely-on-time
            active: true
        });

        cidToListingId[ipfsCID] = listingId;
        listingCount[msg.sender]++;
        totalListingsCreated[msg.sender]++;

        emit ListingRegistered(
            listingId,
            msg.sender,
            ipfsCID,
            contentHash,
            price,
            expiry
        );
    }

    /**
     * @notice Register listing by direct call (no signature needed)
     * @dev For users calling directly from their wallet (msg.sender
     *      proves identity). Simpler UX for direct transactions.
     * @param ipfsCID IPFS content identifier
     * @param contentHash Keccak256 of listing content
     * @param price Listing price in XOM (18 decimals)
     * @param expiry Expiry timestamp (0 = default 60 days)
     */
    function registerListingDirect(
        bytes32 ipfsCID,
        bytes32 contentHash,
        uint256 price,
        uint256 expiry
    ) external nonReentrant whenNotPaused {
        if (ipfsCID == bytes32(0)) revert InvalidIPFSCID();
        if (contentHash == bytes32(0)) revert InvalidContentHash();
        if (price == 0) revert ZeroPrice();
        if (cidToListingId[ipfsCID] != 0) {
            revert DuplicateListing(ipfsCID);
        }

        if (expiry == 0) {
            // solhint-disable-next-line not-rely-on-time
            expiry = block.timestamp + defaultExpiry;
        }

        // solhint-disable-next-line not-rely-on-time
        if (expiry > block.timestamp + MAX_EXPIRY_DURATION) {
            revert ExpiryTooFar(
                block.timestamp + MAX_EXPIRY_DURATION // solhint-disable-line not-rely-on-time
            );
        }

        uint256 listingId = nextListingId++;

        listings[listingId] = Listing({
            creator: msg.sender,
            ipfsCID: ipfsCID,
            contentHash: contentHash,
            price: price,
            expiry: expiry,
            createdAt: block.timestamp, // solhint-disable-line not-rely-on-time
            active: true
        });

        cidToListingId[ipfsCID] = listingId;
        listingCount[msg.sender]++;
        totalListingsCreated[msg.sender]++;

        emit ListingRegistered(
            listingId,
            msg.sender,
            ipfsCID,
            contentHash,
            price,
            expiry
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //                      LISTING MANAGEMENT
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Delist a listing (creator only)
     * @dev Validators cannot delist — only the creator can
     * @param listingId ID of listing to delist
     */
    function delistListing(
        uint256 listingId
    ) external nonReentrant {
        Listing storage l = listings[listingId];
        if (l.creator == address(0)) revert ListingNotFound(listingId);
        if (l.creator != msg.sender) revert NotListingCreator();
        if (!l.active) revert ListingNotFound(listingId);

        l.active = false;
        listingCount[msg.sender]--;

        emit ListingDelisted(listingId, msg.sender);
    }

    /**
     * @notice Renew a listing's expiry (creator only)
     * @param listingId ID of listing to renew
     * @param additionalDuration Seconds to add to current expiry
     */
    function renewListing(
        uint256 listingId,
        uint256 additionalDuration
    ) external nonReentrant {
        Listing storage l = listings[listingId];
        if (l.creator == address(0)) revert ListingNotFound(listingId);
        if (l.creator != msg.sender) revert NotListingCreator();
        if (!l.active) revert ListingNotFound(listingId);

        // Calculate new expiry from now (even if previously expired)
        // solhint-disable-next-line not-rely-on-time
        uint256 base = block.timestamp > l.expiry
            ? block.timestamp
            : l.expiry;
        uint256 newExpiry = base + additionalDuration;

        // solhint-disable-next-line not-rely-on-time
        if (newExpiry > block.timestamp + MAX_EXPIRY_DURATION) {
            revert ExpiryTooFar(
                block.timestamp + MAX_EXPIRY_DURATION // solhint-disable-line not-rely-on-time
            );
        }

        l.expiry = newExpiry;

        emit ListingRenewed(listingId, newExpiry);
    }

    /**
     * @notice Update listing price (creator only)
     * @param listingId ID of listing
     * @param newPrice New price in XOM (18 decimals)
     */
    function updatePrice(
        uint256 listingId,
        uint256 newPrice
    ) external nonReentrant {
        if (newPrice == 0) revert ZeroPrice();

        Listing storage l = listings[listingId];
        if (l.creator == address(0)) revert ListingNotFound(listingId);
        if (l.creator != msg.sender) revert NotListingCreator();
        if (!l.active) revert ListingNotFound(listingId);

        uint256 oldPrice = l.price;
        l.price = newPrice;

        emit ListingPriceUpdated(listingId, oldPrice, newPrice);
    }

    // ══════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Verify content against on-chain hash
     * @param listingId ID of listing
     * @param contentHash Content hash to verify
     * @return matches True if content hash matches on-chain record
     */
    function verifyContent(
        uint256 listingId,
        bytes32 contentHash
    ) external view returns (bool matches) {
        Listing storage l = listings[listingId];
        if (l.creator == address(0)) revert ListingNotFound(listingId);
        return l.contentHash == contentHash;
    }

    /**
     * @notice Check if a listing is active and not expired
     * @param listingId ID of listing
     * @return True if active and not expired
     */
    function isListingValid(
        uint256 listingId
    ) external view returns (bool) {
        Listing storage l = listings[listingId];
        if (l.creator == address(0)) return false;
        if (!l.active) return false;
        // solhint-disable-next-line not-rely-on-time
        return block.timestamp <= l.expiry;
    }

    /**
     * @notice Get listing by IPFS CID
     * @param ipfsCID IPFS content identifier
     * @return listingId The listing ID (0 if not found)
     */
    function getListingByCID(
        bytes32 ipfsCID
    ) external view returns (uint256 listingId) {
        return cidToListingId[ipfsCID];
    }

    /**
     * @notice Get the current nonce for a creator (for signing)
     * @param creator Creator address
     * @return Current nonce value
     */
    function getNonce(
        address creator
    ) external view returns (uint256) {
        return nonces[creator];
    }

    /**
     * @notice Get the EIP-712 domain separator
     * @return Domain separator hash
     */
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ══════════════════════════════════════════════════════════════════
    //                        ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Update default expiry duration
     * @param _defaultExpiry New default in seconds
     */
    function setDefaultExpiry(
        uint256 _defaultExpiry
    ) external onlyRole(MARKETPLACE_ADMIN_ROLE) {
        defaultExpiry = _defaultExpiry;
    }

    /// @notice Pause the contract
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ══════════════════════════════════════════════════════════════════
    //                       INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Authorize UUPS upgrades
     * @param newImplementation New implementation address
     */
    // solhint-disable-next-line no-unused-vars
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
