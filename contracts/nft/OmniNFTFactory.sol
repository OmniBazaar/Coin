// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable2Step, Ownable} from
    "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC2771Context} from
    "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from
    "@openzeppelin/contracts/utils/Context.sol";

/**
 * @title IOmniNFTCollection
 * @author OmniBazaar Development Team
 * @notice Minimal interface for initializing a cloned collection.
 * @dev Called by OmniNFTFactory immediately after ERC-1167 cloning.
 */
interface IOmniNFTCollection {
    /**
     * @notice Initialize a freshly cloned collection.
     * @param _owner Creator / owner address.
     * @param _name Collection name.
     * @param _symbol Collection symbol.
     * @param _maxSupply Maximum mintable tokens.
     * @param _royaltyBps Royalty in basis points.
     * @param _royaltyRecipient Address that receives royalties.
     * @param _unrevealedURI URI shown before reveal.
     */
    function initialize(
        address _owner,
        string calldata _name,
        string calldata _symbol,
        uint256 _maxSupply,
        uint96 _royaltyBps,
        address _royaltyRecipient,
        string calldata _unrevealedURI
    ) external;
}

/**
 * @title OmniNFTFactory
 * @author OmniBazaar Development Team
 * @notice Deploys ERC-1167 minimal proxy clones of OmniNFTCollection.
 * @dev Each `createCollection` call produces a new, independently-owned
 *      NFT collection at a unique address. The factory tracks all
 *      deployed collections. Platform fee (platformFeeBps) is stored
 *      on-chain for transparency and enforced off-chain by the platform
 *      indexer when processing primary sales from factory-deployed
 *      collections. The fee percentage is included in the
 *      CollectionCreated event for auditability.
 */
contract OmniNFTFactory is Ownable2Step, ERC2771Context {
    // ── Constants ────────────────────────────────────────────────────
    /// @notice Maximum platform fee: 10 % (1000 basis points).
    uint16 public constant MAX_PLATFORM_FEE_BPS = 1000;
    /// @notice Maximum number of collections deployable via this factory.
    uint256 public constant MAX_COLLECTIONS = 10000;

    // ── Storage ──────────────────────────────────────────────────────
    /// @notice Implementation contract for ERC-1167 clones.
    address public implementation;
    /// @notice Platform fee in bps on primary sales (default 2.5 %).
    uint16 public platformFeeBps;
    /// @notice Array of all deployed collection addresses.
    address[] public collections;
    /// @notice Whether an address was deployed by this factory.
    mapping(address => bool) public isFactoryCollection;
    /// @notice Collections deployed by a specific creator.
    mapping(address => address[]) public creatorCollections;

    // ── Events ───────────────────────────────────────────────────────
    /**
     * @notice Emitted when a new collection is deployed.
     * @dev M-02: Includes platformFeeBps so off-chain indexers can
     *      enforce the fee that was in effect at deployment time.
     * @param collection  The deployed clone address.
     * @param creator     The collection owner.
     * @param name        Collection name.
     * @param symbol      Collection symbol.
     * @param maxSupply   Maximum token supply.
     * @param royaltyBps  Royalty in basis points.
     * @param feeBps      Platform fee in basis points at creation time.
     */
    event CollectionCreated(
        address indexed collection,
        address indexed creator,
        string name,
        string symbol,
        uint256 indexed maxSupply,
        uint96 royaltyBps,
        uint16 feeBps
    );

    /// @notice Emitted when the platform fee is updated.
    /// @param newFeeBps New fee in basis points.
    event PlatformFeeUpdated(uint16 indexed newFeeBps);

    /// @notice Emitted when the implementation address is updated.
    /// @param newImplementation New implementation address.
    event ImplementationUpdated(
        address indexed newImplementation
    );

    // ── Custom errors ────────────────────────────────────────────────
    /// @dev Thrown when the implementation address is zero.
    error InvalidImplementation();
    /// @dev Thrown when the platform fee exceeds the maximum.
    error FeeTooHigh();
    /// @dev Thrown when maxSupply is zero.
    error InvalidMaxSupply();
    /// @dev Thrown when the factory has reached MAX_COLLECTIONS.
    error TooManyCollections();

    // ── Constructor ──────────────────────────────────────────────────
    /**
     * @notice Deploy the factory with the given implementation.
     * @param _implementation OmniNFTCollection implementation.
     * @param trustedForwarder_ Trusted ERC-2771 forwarder address.
     */
    constructor(
        address _implementation,
        address trustedForwarder_
    ) Ownable(msg.sender) ERC2771Context(trustedForwarder_) {
        if (_implementation == address(0)) {
            revert InvalidImplementation();
        }
        implementation = _implementation;
        platformFeeBps = 250; // 2.5%
    }

    // ── Collection creation ──────────────────────────────────────────
    /**
     * @notice Deploy a new NFT collection as a minimal proxy clone.
     * @param collectionName  Collection name.
     * @param collectionSymbol Collection symbol.
     * @param maxSupply        Maximum token supply.
     * @param royaltyBps       Royalty in basis points (0-2500).
     * @param royaltyRecipient Address receiving royalties.
     * @param unrevealedURI    Placeholder URI before reveal.
     * @return clone           Address of the deployed collection.
     */
    function createCollection(
        string calldata collectionName,
        string calldata collectionSymbol,
        uint256 maxSupply,
        uint96 royaltyBps,
        address royaltyRecipient,
        string calldata unrevealedURI
    ) external returns (address clone) {
        if (maxSupply == 0) revert InvalidMaxSupply();
        // solhint-disable-next-line gas-strict-inequalities
        if (collections.length >= MAX_COLLECTIONS) {
            revert TooManyCollections();
        }

        address caller = _msgSender();

        clone = Clones.clone(implementation);

        IOmniNFTCollection(clone).initialize(
            caller,
            collectionName,
            collectionSymbol,
            maxSupply,
            royaltyBps,
            royaltyRecipient,
            unrevealedURI
        );

        collections.push(clone);
        isFactoryCollection[clone] = true;
        creatorCollections[caller].push(clone);

        // M-02: Include platformFeeBps in event for off-chain enforcement
        emit CollectionCreated(
            clone,
            caller,
            collectionName,
            collectionSymbol,
            maxSupply,
            royaltyBps,
            platformFeeBps
        );
    }

    // ── Admin ────────────────────────────────────────────────────────
    /**
     * @notice Update the platform fee.
     * @param newFeeBps New fee in basis points.
     */
    function setPlatformFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_PLATFORM_FEE_BPS) revert FeeTooHigh();
        platformFeeBps = newFeeBps;
        emit PlatformFeeUpdated(newFeeBps);
    }

    /**
     * @notice Update the implementation contract for future clones.
     * @param _implementation New implementation address.
     */
    function setImplementation(
        address _implementation
    ) external onlyOwner {
        if (_implementation == address(0)) {
            revert InvalidImplementation();
        }
        implementation = _implementation;
        emit ImplementationUpdated(_implementation);
    }

    // ── View helpers ─────────────────────────────────────────────────
    /**
     * @notice Total number of collections deployed.
     * @return count Number of collections.
     */
    function totalCollections()
        external
        view
        returns (uint256)
    {
        return collections.length;
    }

    /**
     * @notice Number of collections created by a specific address.
     * @param creator Creator address.
     * @return count Number of collections.
     */
    function creatorCollectionCount(
        address creator
    ) external view returns (uint256) {
        return creatorCollections[creator].length;
    }

    // ── ERC-2771 overrides (Context diamond resolution) ───────────

    /**
     * @notice Return the sender of the call, accounting for
     *         ERC-2771 meta-transactions.
     * @dev Delegates to ERC2771Context to extract the original
     *      sender when the call comes from the trusted forwarder.
     * @return The resolved sender address.
     */
    function _msgSender()
        internal
        view
        override(Context, ERC2771Context)
        returns (address)
    {
        return ERC2771Context._msgSender();
    }

    /**
     * @notice Return the calldata of the call, accounting for
     *         ERC-2771 meta-transactions.
     * @dev Delegates to ERC2771Context to strip the appended
     *      sender address when the call comes from the trusted
     *      forwarder.
     * @return The resolved calldata.
     */
    function _msgData()
        internal
        view
        override(Context, ERC2771Context)
        returns (bytes calldata)
    {
        return ERC2771Context._msgData();
    }

    /**
     * @notice Return the context suffix length for ERC-2771.
     * @dev ERC-2771 appends 20 bytes (the sender address) to
     *      the calldata.
     * @return Length of the context suffix (20).
     */
    function _contextSuffixLength()
        internal
        view
        override(Context, ERC2771Context)
        returns (uint256)
    {
        return ERC2771Context._contextSuffixLength();
    }
}
