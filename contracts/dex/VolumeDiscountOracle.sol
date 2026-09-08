// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IFeeOracle} from "./DEXSettlement.sol";

/**
 * @title VolumeDiscountOracle
 * @author OmniCoin Development Team
 * @notice Implements IFeeOracle to provide volume-based taker fee
 *         discounts. Validators update each trader's 30-day rolling
 *         volume snapshot; the oracle returns a discount (in basis
 *         points) based on configurable tier thresholds.
 *
 * Default tiers (owner-configurable, immediate during Pioneer Phase):
 *   < 100K USD:    0 bps discount
 *   100K–1M USD:   2 bps discount
 *   1M–10M USD:    5 bps discount
 *   10M+ USD:      8 bps discount
 *
 * @dev Volume discount is per-trader, not per-pair. The `pairHash`
 *      parameter in `getDiscountBps` is intentionally ignored — the
 *      same discount applies across all trading pairs for a given
 *      trader. This is by design: volume-based loyalty rewards are
 *      earned on total platform activity, not isolated per market.
 *
 *      Write operations (`updateVolumes`) require dual-signer
 *      authorization (≥2 distinct authorized updaters). The caller
 *      (msg.sender) must be an authorized updater, and a valid ECDSA
 *      signature from a second, distinct authorized updater over the
 *      same (traders, volumes) data must be provided.
 *
 *      Tier changes are immediate (owner-controlled) during Pioneer
 *      Phase; a governance timelock will be added post-Pioneer.
 *
 *      This contract is intentionally kept gas-cheap on read (view).
 *      Write operations (`updateVolumes`) are validator-only batch jobs.
 */
contract VolumeDiscountOracle is IFeeOracle, Ownable2Step {

    // ================================================================
    // TYPES
    // ================================================================

    /**
     * @notice A single volume tier: traders whose 30-day volume is at
     *         or above `threshold` earn `discountBps` off taker fees.
     */
    struct VolumeTier {
        /** Minimum 30-day volume in USD (18 decimals) */
        uint256 threshold;
        /** Discount in basis points */
        uint256 discountBps;
    }

    // ================================================================
    // CONSTANTS
    // ================================================================

    /// @notice Maximum number of tiers (storage safety)
    uint256 public constant MAX_TIERS = 10;

    /// @notice Maximum discount in basis points (cannot exceed taker fee)
    uint256 public constant MAX_DISCOUNT_BPS = 100;

    /// @notice Maximum volume per trader (1 trillion USD, 18 decimals)
    uint256 public constant MAX_VOLUME = 1_000_000_000_000e18;

    /// @notice Maximum staleness before discount reverts to 0 (7 days)
    uint256 public constant MAX_STALENESS = 7 days;

    /// @notice Maximum number of traders per updateVolumes batch
    uint256 public constant MAX_BATCH_SIZE = 200;

    // ================================================================
    // STATE
    // ================================================================

    /// @notice 30-day rolling volume per trader (USD, 18 decimals)
    mapping(address => uint256) public traderVolume30d;

    /// @notice Timestamp of last volume update per trader
    mapping(address => uint256) public lastUpdateTimestamp;

    /// @notice Addresses authorized to call `updateVolumes`
    mapping(address => bool) public authorizedUpdaters;

    /// @notice Ordered array of volume tiers (ascending threshold)
    VolumeTier[] public tiers;

    // ================================================================
    // EVENTS
    // ================================================================

    /**
     * @notice Emitted when trader volumes are batch-updated
     * @param primarySigner First authorized updater (msg.sender)
     * @param coSigner Second authorized updater (recovered from signature)
     * @param count Number of traders updated
     */
    event VolumesUpdated(
        address indexed primarySigner,
        address indexed coSigner,
        uint256 indexed count
    );

    /**
     * @notice Emitted when an updater is added or removed
     * @param updater Updater address
     * @param authorized True if added, false if removed
     */
    event UpdaterChanged(
        address indexed updater,
        bool indexed authorized
    );

    /// @notice Emitted when tiers are updated
    event TiersUpdated();

    // ================================================================
    // ERRORS
    // ================================================================

    /// @notice Caller is not an authorized updater
    error NotAuthorized();

    /// @notice Zero address provided where non-zero is required
    error InvalidAddress();

    /// @notice Array length mismatch between traders and volumes
    error ArrayLengthMismatch();

    /// @notice Too many tiers
    error TooManyTiers();

    /// @notice Discount exceeds maximum
    error DiscountTooHigh();

    /// @notice Tiers not sorted by ascending threshold
    error TiersNotSorted();

    /// @notice Volume exceeds maximum allowed value
    error VolumeTooHigh();

    /// @notice Owner cannot be an updater or receive volume updates
    error OwnerCannotBeUpdater();

    /// @notice Primary and co-signer must be distinct
    error SignersMustDiffer();

    /// @notice Co-signer signature is invalid or signer not authorized
    error InvalidSignature();

    /// @notice updateVolumes batch exceeds the maximum size
    error BatchTooLarge();

    // ================================================================
    // CONSTRUCTOR
    // ================================================================

    /**
     * @notice Deploy the oracle with default tiers and initial updaters
     * @param owner_ Owner address (can manage updaters and tiers)
     * @param initialUpdaters Addresses authorized to update volumes
     */
    constructor(
        address owner_,
        address[] memory initialUpdaters
    ) Ownable(owner_) {
        // Default tiers
        tiers.push(VolumeTier({
            threshold: 100_000e18,
            discountBps: 2
        }));
        tiers.push(VolumeTier({
            threshold: 1_000_000e18,
            discountBps: 5
        }));
        tiers.push(VolumeTier({
            threshold: 10_000_000e18,
            discountBps: 8
        }));

        for (uint256 i; i < initialUpdaters.length; ++i) {
            if (initialUpdaters[i] == address(0)) {
                revert InvalidAddress();
            }
            if (initialUpdaters[i] == owner_) {
                revert OwnerCannotBeUpdater();
            }
            authorizedUpdaters[initialUpdaters[i]] = true;
            emit UpdaterChanged(initialUpdaters[i], true);
        }
    }

    // ================================================================
    // EXTERNAL — UPDATER FUNCTIONS
    // ================================================================

    /**
     * @notice Batch-update 30-day volume for a list of traders.
     *         Requires dual authorization: msg.sender must be an
     *         authorized updater AND a valid ECDSA signature from a
     *         second, distinct authorized updater over the same data.
     * @param traders Array of trader addresses
     * @param volumes Array of 30-day volumes (USD, 18 decimals)
     * @param coSignerSignature ECDSA signature (65 bytes: r,s,v) from a
     *        second authorized updater over the Ethereum signed message
     *        hash of keccak256(abi.encode(traders, volumes))
     */
    function updateVolumes(
        address[] calldata traders,
        uint256[] calldata volumes,
        bytes calldata coSignerSignature
    ) external {
        if (!authorizedUpdaters[msg.sender]) {
            revert NotAuthorized();
        }
        if (traders.length != volumes.length) {
            revert ArrayLengthMismatch();
        }
        if (traders.length > MAX_BATCH_SIZE) {
            revert BatchTooLarge();
        }

        // Recover co-signer from signature
        bytes32 digest = keccak256(abi.encode(traders, volumes));
        address coSigner = _recoverSigner(
            _toEthSignedMessageHash(digest),
            coSignerSignature
        );

        if (coSigner == msg.sender) {
            revert SignersMustDiffer();
        }
        if (!authorizedUpdaters[coSigner]) {
            revert InvalidSignature();
        }

        address owner_ = owner();
        uint256 now_ = block.timestamp; // solhint-disable-line not-rely-on-time
        for (uint256 i; i < traders.length; ++i) {
            if (volumes[i] > MAX_VOLUME) {
                revert VolumeTooHigh();
            }
            if (traders[i] == owner_) {
                revert OwnerCannotBeUpdater();
            }
            traderVolume30d[traders[i]] = volumes[i];
            lastUpdateTimestamp[traders[i]] = now_;
        }

        emit VolumesUpdated(msg.sender, coSigner, traders.length);
    }

    // ================================================================
    // EXTERNAL — IFeeOracle
    // ================================================================

    /**
     * @inheritdoc IFeeOracle
     * @dev Returns the highest discount tier the trader qualifies for
     *      based on their 30-day volume. O(n) where n = tier count
     *      (max 10), so gas is bounded.
     *
     *      The `pairHash` parameter is intentionally ignored — volume
     *      discount is per-trader, not per-pair. A trader's discount
     *      applies uniformly across all trading pairs.
     *
     *      Returns 0 if the trader's volume data is stale (older than
     *      MAX_STALENESS) or has never been updated.
     */
    function getDiscountBps(
        address trader,
        bytes32 /* pairHash */
    ) external view override returns (uint256 discountBps) {
        uint256 volume = traderVolume30d[trader];
        uint256 lastUpdate = lastUpdateTimestamp[trader];

        // Staleness check: if never updated or stale, return 0
        if (
            lastUpdate == 0 ||
            block.timestamp > lastUpdate + MAX_STALENESS // solhint-disable-line not-rely-on-time
        ) {
            return 0;
        }

        uint256 len = tiers.length;

        // Iterate descending to find highest qualifying tier
        for (uint256 i = len; i > 0; --i) {
            if (volume >= tiers[i - 1].threshold) {
                return tiers[i - 1].discountBps;
            }
        }
        // Below all thresholds: no discount
        return 0;
    }

    // ================================================================
    // EXTERNAL — OWNER ADMIN
    // ================================================================

    /**
     * @notice Add an authorized volume updater.
     *         Owner address cannot be added as an updater.
     * @param updater Address to authorize
     */
    function addUpdater(address updater) external onlyOwner {
        if (updater == address(0)) revert InvalidAddress();
        if (updater == owner()) revert OwnerCannotBeUpdater();
        authorizedUpdaters[updater] = true;
        emit UpdaterChanged(updater, true);
    }

    /**
     * @notice Remove an authorized volume updater
     * @param updater Address to de-authorize
     */
    function removeUpdater(address updater) external onlyOwner {
        authorizedUpdaters[updater] = false;
        emit UpdaterChanged(updater, false);
    }

    /**
     * @notice Set volume tiers immediately (Pioneer Phase — owner direct).
     *         Replaces the entire tier list atomically.
     * @param newTiers Array of VolumeTier structs (ascending threshold)
     */
    function setTiers(
        VolumeTier[] calldata newTiers
    ) external onlyOwner {
        if (newTiers.length > MAX_TIERS) revert TooManyTiers();

        // Validate ascending + discount bounds
        for (uint256 i; i < newTiers.length; ++i) {
            if (newTiers[i].discountBps > MAX_DISCOUNT_BPS) {
                revert DiscountTooHigh();
            }
            if (
                i > 0 &&
                newTiers[i].threshold <= newTiers[i - 1].threshold
            ) {
                revert TiersNotSorted();
            }
        }

        delete tiers;
        for (uint256 i; i < newTiers.length; ++i) {
            tiers.push(newTiers[i]);
        }

        emit TiersUpdated();
    }

    // ================================================================
    // VIEW — TIER INSPECTION
    // ================================================================

    /**
     * @notice Return the number of configured tiers
     * @return count Number of tiers
     */
    function tierCount() external view returns (uint256 count) {
        return tiers.length;
    }

    // ================================================================
    // INTERNAL — SIGNATURE VERIFICATION
    // ================================================================

    /**
     * @notice Produce the Ethereum signed message hash prefix
     * @param hash The raw message hash
     * @return The prefixed hash per EIP-191
     */
    function _toEthSignedMessageHash(
        bytes32 hash
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)
        );
    }

    /**
     * @notice Recover the signer address from an ECDSA signature
     * @param ethSignedMessageHash The prefixed message hash
     * @param signature 65-byte ECDSA signature (r, s, v)
     * @return signer The recovered address
     * @dev Uses ecrecover directly; rejects malleable signatures
     *      (s in upper half) and non-standard v values
     */
    function _recoverSigner(
        bytes32 ethSignedMessageHash,
        bytes calldata signature
    ) internal pure returns (address signer) {
        if (signature.length != 65) {
            revert InvalidSignature();
        }

        bytes32 r;
        bytes32 s;
        uint8 v;

        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }

        // Reject malleable signatures (s in upper half of curve order)
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidSignature();
        }

        if (v < 27) {
            v += 27;
        }
        if (v != 27 && v != 28) {
            revert InvalidSignature();
        }

        signer = ecrecover(ethSignedMessageHash, v, r, s);
        if (signer == address(0)) {
            revert InvalidSignature();
        }
    }
}
