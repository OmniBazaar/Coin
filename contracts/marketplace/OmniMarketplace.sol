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

/// @notice Invalid expiry duration (zero)
error InvalidExpiry();

/// @notice Daily listing creation limit exceeded (anti-gaming)
error DailyLimitExceeded();

/// @notice Upgrade target does not match the scheduled implementation
error UnauthorizedUpgrade();

/// @notice Upgrade timelock period has not elapsed
error UpgradeTimelockActive();

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
 *      - Daily listing rate limit (anti-gaming)
 *      - Upgrade timelock (48h)
 *
 * Architecture:
 * - Creator signs listing data with EIP-712 before submission
 * - Relayer submits the signed transaction with explicit creator param
 * - Anyone can verify content matches on-chain hash
 * - Only creator can delist (validators cannot censor)
 * - Lightweight: ~200 bytes storage per listing
 *
 * Security:
 * - UUPS upgradeable with 48-hour timelock, Pausable, ReentrancyGuard
 * - EIP-712 signatures prevent validator forgery
 * - Content hash prevents post-creation tampering
 * - Only creator can modify/delist their own listings
 * - Daily listing cap prevents participation score gaming
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

    /// @notice Maximum listings any creator may register per day
    /// @dev Anti-gaming measure: prevents participation score inflation
    ///      via mass listing creation
    uint256 public constant MAX_LISTINGS_PER_DAY = 50;

    /// @notice Timelock delay for UUPS upgrades (48 hours)
    uint256 public constant UPGRADE_DELAY = 48 hours;

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

    /// @notice Per-creator daily listing count (creator => day => count)
    /// @dev Day is computed as block.timestamp / 1 days
    mapping(address => mapping(uint256 => uint256))
        private dailyListingCount;

    /// @notice Pending implementation address for timelock upgrade
    address public pendingImplementation;

    /// @notice Timestamp at which the pending upgrade becomes executable
    uint256 public upgradeScheduledAt;

    // ══════════════════════════════════════════════════════════════════
    //                        STORAGE GAP
    // ══════════════════════════════════════════════════════════════════

    /**
     * @dev Storage gap for future upgrades.
     * @notice Reserves storage slots for adding new state variables in
     *         future proxy upgrades without shifting inherited contract
     *         storage.
     *
     * Sequential (non-mapping) state variable slots used:
     *   - nextListingId          (1 slot)
     *   - defaultExpiry          (1 slot)
     *   - pendingImplementation  (1 slot)
     *   - upgradeScheduledAt     (1 slot)
     * Total sequential slots: 4
     * Mappings (5): listings, listingCount, totalListingsCreated,
     *   nonces, cidToListingId, dailyListingCount
     *   — do not consume sequential slots per OZ convention
     *
     * Gap = 50 - 4 = 46 reserved slots
     * (Reduced from original 43 estimate after final slot audit)
     */
    uint256[46] private __gap;

    // ══════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Emitted when a listing is registered on-chain
    /// @param listingId Unique listing identifier
    /// @param creator Address that created the listing
    /// @param ipfsCID IPFS content identifier
    /// @param contentHash Keccak256 hash of the listing content
    /// @param price Listing price in XOM (18 decimals)
    /// @param expiry Expiry timestamp
    event ListingRegistered(
        uint256 indexed listingId,
        address indexed creator,
        bytes32 ipfsCID,
        bytes32 contentHash,
        uint256 price,
        uint256 expiry
    );

    /// @notice Emitted when a listing is delisted by creator
    /// @param listingId Delisted listing identifier
    /// @param creator Address of the listing creator
    event ListingDelisted(
        uint256 indexed listingId,
        address indexed creator
    );

    /// @notice Emitted when a listing is renewed
    /// @param listingId Renewed listing identifier
    /// @param newExpiry New expiry timestamp
    event ListingRenewed(
        uint256 indexed listingId,
        uint256 newExpiry
    );

    /// @notice Emitted when listing price is updated
    /// @param listingId Updated listing identifier
    /// @param oldPrice Previous price in XOM
    /// @param newPrice New price in XOM
    event ListingPriceUpdated(
        uint256 indexed listingId,
        uint256 oldPrice,
        uint256 newPrice
    );

    /// @notice Emitted when the default expiry duration is changed
    /// @param oldExpiry Previous default expiry in seconds
    /// @param newExpiry New default expiry in seconds
    event DefaultExpiryUpdated(
        uint256 oldExpiry,
        uint256 newExpiry
    );

    /// @notice Emitted when a UUPS upgrade is scheduled
    /// @param newImplementation Address of the new implementation
    /// @param executeAfter Timestamp after which the upgrade can execute
    event UpgradeScheduled(
        address indexed newImplementation,
        uint256 executeAfter
    );

    /// @notice Emitted when a scheduled upgrade is cancelled
    /// @param cancelledImplementation Address that was cancelled
    event UpgradeCancelled(address indexed cancelledImplementation);

    // ══════════════════════════════════════════════════════════════════
    //                           INITIALIZER
    // ══════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the marketplace registry
     * @dev Sets up access control, UUPS, reentrancy guard, pause,
     *      and EIP-712 domain. Grants admin roles to deployer.
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
     * @dev Relayer/validator relays this transaction but cannot forge
     *      the listing because only the creator holds the signing key.
     *      The creator address is passed explicitly so that a relayer
     *      (msg.sender != creator) can submit on the creator's behalf.
     *
     *      M-02 fix: Preserves the original expiry value (including 0)
     *      for signature verification. Default expiry substitution
     *      occurs after signature check.
     *
     *      M-04 fix: Enforces MAX_LISTINGS_PER_DAY rate limit per
     *      creator.
     *
     *      M-05 fix: Accepts explicit `creator` parameter so that
     *      relayers can submit signed listings on behalf of creators.
     *
     * @param creator Address of the listing creator (signer)
     * @param ipfsCID IPFS content identifier
     * @param contentHash Keccak256 hash of listing content
     * @param price Listing price in XOM (18 decimals)
     * @param expiry Expiry timestamp (0 = use default)
     * @param signature Creator's EIP-712 signature
     */
    function registerListing(
        address creator,
        bytes32 ipfsCID,
        bytes32 contentHash,
        uint256 price,
        uint256 expiry,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        if (creator == address(0)) revert ZeroAddress();
        if (ipfsCID == bytes32(0)) revert InvalidIPFSCID();
        if (contentHash == bytes32(0)) revert InvalidContentHash();
        if (price == 0) revert ZeroPrice();
        if (cidToListingId[ipfsCID] != 0) {
            revert DuplicateListing(ipfsCID);
        }

        // M-04: Rate limit per creator per day
        // solhint-disable-next-line not-rely-on-time
        uint256 today = block.timestamp / 1 days;
        if (
            dailyListingCount[creator][today] >=
            MAX_LISTINGS_PER_DAY
        ) {
            revert DailyLimitExceeded();
        }

        // Get creator nonce for replay protection
        uint256 nonce = nonces[creator];

        // M-02: Preserve original expiry for signature verification
        uint256 signedExpiry = expiry;

        // Verify EIP-712 signature against what creator actually signed
        bytes32 structHash = keccak256(
            abi.encode(
                LISTING_TYPEHASH,
                ipfsCID,
                contentHash,
                price,
                signedExpiry,
                nonce
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);

        // M-05: Verify signer matches the explicit creator param
        if (signer != creator) revert InvalidSignature();

        // Increment nonce
        nonces[creator] = nonce + 1;

        // Apply default expiry after signature verification
        if (expiry == 0) {
            // solhint-disable-next-line not-rely-on-time
            expiry = block.timestamp + defaultExpiry;
        }

        // Cap expiry
        // solhint-disable-next-line not-rely-on-time
        if (expiry > block.timestamp + MAX_EXPIRY_DURATION) {
            revert ExpiryTooFar(
                // solhint-disable-next-line not-rely-on-time
                block.timestamp + MAX_EXPIRY_DURATION
            );
        }

        // M-04: Increment daily count
        dailyListingCount[creator][today]++;

        // Create listing
        uint256 listingId = nextListingId++;

        listings[listingId] = Listing({
            creator: creator,
            ipfsCID: ipfsCID,
            contentHash: contentHash,
            price: price,
            expiry: expiry,
            // solhint-disable-next-line not-rely-on-time
            createdAt: block.timestamp,
            active: true
        });

        cidToListingId[ipfsCID] = listingId;
        listingCount[creator]++;
        totalListingsCreated[creator]++;

        emit ListingRegistered(
            listingId,
            creator,
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
     *
     *      M-04 fix: Enforces MAX_LISTINGS_PER_DAY rate limit.
     *
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

        // M-04: Rate limit per creator per day
        // solhint-disable-next-line not-rely-on-time
        uint256 today = block.timestamp / 1 days;
        if (
            dailyListingCount[msg.sender][today] >=
            MAX_LISTINGS_PER_DAY
        ) {
            revert DailyLimitExceeded();
        }

        if (expiry == 0) {
            // solhint-disable-next-line not-rely-on-time
            expiry = block.timestamp + defaultExpiry;
        }

        // solhint-disable-next-line not-rely-on-time
        if (expiry > block.timestamp + MAX_EXPIRY_DURATION) {
            revert ExpiryTooFar(
                // solhint-disable-next-line not-rely-on-time
                block.timestamp + MAX_EXPIRY_DURATION
            );
        }

        // M-04: Increment daily count
        dailyListingCount[msg.sender][today]++;

        uint256 listingId = nextListingId++;

        listings[listingId] = Listing({
            creator: msg.sender,
            ipfsCID: ipfsCID,
            contentHash: contentHash,
            price: price,
            expiry: expiry,
            // solhint-disable-next-line not-rely-on-time
            createdAt: block.timestamp,
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
     * @dev Validators cannot delist — only the creator can.
     *      Intentionally callable while paused so users can delist
     *      during emergencies.
     *
     *      M-03 fix: Clears the CID deduplication entry so the same
     *      CID can be re-listed after delisting.
     *
     * @param listingId ID of listing to delist
     */
    function delistListing(
        uint256 listingId
    ) external nonReentrant {
        Listing storage l = listings[listingId];
        if (l.creator == address(0)) {
            revert ListingNotFound(listingId);
        }
        if (l.creator != msg.sender) revert NotListingCreator();
        if (!l.active) revert ListingNotFound(listingId);

        l.active = false;
        listingCount[msg.sender]--;

        // M-03: Clear CID deduplication so CID can be re-listed
        delete cidToListingId[l.ipfsCID];

        emit ListingDelisted(listingId, msg.sender);
    }

    /**
     * @notice Renew a listing's expiry (creator only)
     * @dev L-02 fix: Added whenNotPaused — renewals should not
     *      occur during emergencies.
     * @param listingId ID of listing to renew
     * @param additionalDuration Seconds to add to current expiry
     */
    function renewListing(
        uint256 listingId,
        uint256 additionalDuration
    ) external nonReentrant whenNotPaused {
        Listing storage l = listings[listingId];
        if (l.creator == address(0)) {
            revert ListingNotFound(listingId);
        }
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
                // solhint-disable-next-line not-rely-on-time
                block.timestamp + MAX_EXPIRY_DURATION
            );
        }

        l.expiry = newExpiry;

        emit ListingRenewed(listingId, newExpiry);
    }

    /**
     * @notice Update listing price (creator only)
     * @dev Intentionally callable while paused so users can update
     *      prices during emergencies.
     * @param listingId ID of listing
     * @param newPrice New price in XOM (18 decimals)
     */
    function updatePrice(
        uint256 listingId,
        uint256 newPrice
    ) external nonReentrant {
        if (newPrice == 0) revert ZeroPrice();

        Listing storage l = listings[listingId];
        if (l.creator == address(0)) {
            revert ListingNotFound(listingId);
        }
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
        if (l.creator == address(0)) {
            revert ListingNotFound(listingId);
        }
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

    /**
     * @notice Get remaining daily listing quota for a creator
     * @param creator Creator address to check
     * @return remaining Listings remaining for today
     */
    function dailyListingsRemaining(
        address creator
    ) external view returns (uint256 remaining) {
        // solhint-disable-next-line not-rely-on-time
        uint256 today = block.timestamp / 1 days;
        uint256 used = dailyListingCount[creator][today];
        if (used >= MAX_LISTINGS_PER_DAY) return 0;
        return MAX_LISTINGS_PER_DAY - used;
    }

    // ══════════════════════════════════════════════════════════════════
    //                        ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Update default expiry duration
     * @dev L-01 fix: Validates bounds (non-zero, <= MAX_EXPIRY_DURATION)
     *      and emits DefaultExpiryUpdated event.
     * @param _defaultExpiry New default in seconds
     */
    function setDefaultExpiry(
        uint256 _defaultExpiry
    ) external onlyRole(MARKETPLACE_ADMIN_ROLE) {
        if (_defaultExpiry == 0) revert InvalidExpiry();
        if (_defaultExpiry > MAX_EXPIRY_DURATION) {
            revert ExpiryTooFar(MAX_EXPIRY_DURATION);
        }
        uint256 old = defaultExpiry;
        defaultExpiry = _defaultExpiry;
        emit DefaultExpiryUpdated(old, _defaultExpiry);
    }

    /// @notice Pause the contract
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Schedule a UUPS upgrade with timelock delay
     * @dev L-03 fix: Upgrades require a 48-hour waiting period.
     *      The admin calls scheduleUpgrade() first, then after
     *      UPGRADE_DELAY has elapsed, calls upgradeTo/upgradeToAndCall
     *      which triggers _authorizeUpgrade() to validate the timelock.
     * @param newImpl Address of the new implementation contract
     */
    function scheduleUpgrade(
        address newImpl
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newImpl == address(0)) revert ZeroAddress();
        pendingImplementation = newImpl;
        // solhint-disable-next-line not-rely-on-time
        upgradeScheduledAt = block.timestamp + UPGRADE_DELAY;
        emit UpgradeScheduled(newImpl, upgradeScheduledAt);
    }

    /**
     * @notice Cancel a previously scheduled upgrade
     * @dev Allows admin to abort a pending upgrade before the
     *      timelock expires.
     */
    function cancelUpgrade()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        address cancelled = pendingImplementation;
        delete pendingImplementation;
        delete upgradeScheduledAt;
        emit UpgradeCancelled(cancelled);
    }

    // ══════════════════════════════════════════════════════════════════
    //                       INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Authorize UUPS upgrades with timelock validation
     * @dev L-03 fix: Validates that the new implementation matches
     *      the scheduled address and that the timelock delay has
     *      elapsed. Clears pending state after authorization.
     * @param newImplementation New implementation address
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newImplementation != pendingImplementation) {
            revert UnauthorizedUpgrade();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < upgradeScheduledAt) {
            revert UpgradeTimelockActive();
        }
        delete pendingImplementation;
        delete upgradeScheduledAt;
    }
}
