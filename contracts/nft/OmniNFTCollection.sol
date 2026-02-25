// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from
    "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from
    "@openzeppelin/contracts/token/common/ERC2981.sol";
import {MerkleProof} from
    "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Strings} from
    "@openzeppelin/contracts/utils/Strings.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OmniNFTCollection
 * @author OmniBazaar Development Team
 * @notice ERC-721 collection deployed via OmniNFTFactory (ERC-1167).
 * @dev Supports multi-phase minting (whitelist + public), per-wallet
 *      limits, batch minting (with MAX_BATCH_SIZE), deferred reveal,
 *      ERC-2981 royalties, creator withdrawals, and per-clone
 *      name/symbol overrides. Uses an initializer for the clone
 *      pattern.
 */
contract OmniNFTCollection is ERC721, ERC2981, ReentrancyGuard {
    using Strings for uint256;

    // ── Structs ──────────────────────────────────────────────────────
    /**
     * @notice Configuration for a single minting phase.
     * @param price Mint price in wei per token.
     * @param merkleRoot Merkle root for whitelist (bytes32(0) = public).
     * @param maxPerWallet Maximum tokens per wallet in this phase.
     * @param active Whether this phase is currently accepting mints.
     */
    struct PhaseConfig {
        uint256 price;
        bytes32 merkleRoot;
        uint16 maxPerWallet;
        bool active;
    }

    // ── Constants ────────────────────────────────────────────────────
    /// @notice Maximum royalty: 25 % (2500 basis points).
    uint16 public constant MAX_ROYALTY_BPS = 2500;
    /// @notice Maximum tokens per batch mint call.
    uint256 public constant MAX_BATCH_SIZE = 100;

    // ── Storage ──────────────────────────────────────────────────────
    /// @notice Collection owner / creator address.
    address public owner;
    /// @notice Whether the contract has been initialized.
    bool public initialized;
    /// @notice Maximum number of tokens that can ever exist.
    uint256 public maxSupply;
    /// @notice Counter tracking the next token ID to mint.
    uint256 public nextTokenId;
    /// @notice Whether the collection art has been revealed.
    bool public revealed;
    /// @notice Base URI for revealed metadata.
    string private _revealedBaseURI;
    /// @notice URI returned for all tokens before reveal.
    string public unrevealedURI;
    /// @notice Clone-specific collection name.
    string private _collectionName;
    /// @notice Clone-specific collection symbol.
    string private _collectionSymbol;

    /// @notice Currently active minting phase (0 = paused).
    uint8 public activePhase;

    /// @notice Phase configs keyed by phase ID (1-indexed).
    mapping(uint8 => PhaseConfig) public phases;
    /// @notice Number of configured phases.
    uint8 public phaseCount;
    /// @notice Per-wallet mint counts: phase => wallet => count.
    mapping(uint8 => mapping(address => uint256))
        public mintedPerPhase;

    // ── Events ───────────────────────────────────────────────────────
    /// @notice Emitted when one or more tokens are minted.
    /// @param to Recipient address.
    /// @param startTokenId First token ID in the batch.
    /// @param quantity Number of tokens minted.
    event Minted(
        address indexed to,
        uint256 indexed startTokenId,
        uint256 indexed quantity
    );

    /// @notice Emitted when the collection metadata is revealed.
    /// @param baseURI The revealed IPFS base URI.
    event Revealed(string baseURI);

    /// @notice Emitted when the active phase changes.
    /// @param phaseId New active phase ID.
    event PhaseChanged(uint8 indexed phaseId);

    /// @notice Emitted when the creator withdraws revenue.
    /// @param to Recipient of the withdrawal.
    /// @param amount ETH amount withdrawn.
    event Withdrawn(
        address indexed to,
        uint256 indexed amount
    );

    // ── Custom errors ────────────────────────────────────────────────
    /// @dev Thrown when a non-owner calls an owner-only function.
    error NotOwner();
    /// @dev Thrown when initialize is called more than once.
    error AlreadyInitialized();
    /// @dev Thrown when minting would exceed max supply.
    error MaxSupplyExceeded();
    /// @dev Thrown when the caller exceeds per-wallet mint limit.
    error WalletLimitExceeded();
    /// @dev Thrown when the wrong ETH value is sent for minting.
    error IncorrectPayment();
    /// @dev Thrown when minting while the phase is inactive.
    error PhaseNotActive();
    /// @dev Thrown when a whitelist proof is invalid.
    error InvalidProof();
    /// @dev Thrown when a quantity of zero is passed.
    error ZeroQuantity();
    /// @dev Thrown when the royalty basis points exceed 25 %.
    error RoyaltyTooHigh();
    /// @dev Thrown when an ETH transfer fails.
    error TransferFailed();
    /// @dev Thrown when the collection has already been revealed.
    error AlreadyRevealed();
    /// @dev Thrown when the phase is already the requested value.
    error PhaseAlreadySet();
    /// @dev Thrown when batch quantity exceeds MAX_BATCH_SIZE.
    error BatchSizeExceeded();
    /// @dev Thrown when the owner address is zero (M-04).
    error ZeroAddress();

    // ── Modifiers ────────────────────────────────────────────────────
    /// @dev Restricts to the collection owner.
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ── Constructor (disabled for clone pattern) ─────────────────────
    /**
     * @dev Constructor sets the ERC721 name/symbol for the
     *      implementation contract. Clones call `initialize()`.
     */
    constructor() ERC721("OmniNFT", "ONFT") {
        initialized = true;
    }

    // ── Initializer ──────────────────────────────────────────────────
    /**
     * @notice Initialize a freshly cloned collection.
     * @param _owner Creator / owner address.
     * @param _name  Collection name.
     * @param _symbol Collection symbol.
     * @param _maxSupply Maximum mintable tokens.
     * @param _royaltyBps Royalty in basis points (0-2500).
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
    ) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;

        // M-04: Validate owner is non-zero
        if (_owner == address(0)) revert ZeroAddress();
        if (_royaltyBps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();

        owner = _owner;
        maxSupply = _maxSupply;
        unrevealedURI = _unrevealedURI;

        // H-02: Store per-clone name and symbol
        _collectionName = _name;
        _collectionSymbol = _symbol;

        // ERC-2981 default royalty
        if (_royaltyBps > 0 && _royaltyRecipient != address(0)) {
            _setDefaultRoyalty(_royaltyRecipient, _royaltyBps);
        }
    }

    // ── Phase management ─────────────────────────────────────────────
    /**
     * @notice Configure a minting phase.
     * @param phaseId      Phase identifier (1-indexed).
     * @param price        Price per mint in wei.
     * @param maxPerWallet Max mints per wallet in this phase.
     * @param merkleRoot   Merkle root for whitelist.
     */
    function setPhase(
        uint8 phaseId,
        uint256 price,
        uint16 maxPerWallet,
        bytes32 merkleRoot
    ) external onlyOwner {
        if (phaseId == 0) revert ZeroQuantity();
        // M-01: Preserve the active state if reconfiguring the current
        // active phase. Previously, setPhase always set active=false,
        // silently deactivating the live phase.
        bool preserveActive = (phaseId == activePhase)
            && phases[phaseId].active;
        phases[phaseId] = PhaseConfig({
            price: price,
            merkleRoot: merkleRoot,
            maxPerWallet: maxPerWallet,
            active: preserveActive
        });
        if (phaseId > phaseCount) {
            phaseCount = phaseId;
        }
    }

    /**
     * @notice Activate a specific phase; deactivate the previous one.
     * @param phaseId Phase to activate (0 to pause all minting).
     */
    function setActivePhase(uint8 phaseId) external onlyOwner {
        if (phaseId == activePhase) revert PhaseAlreadySet();
        if (activePhase > 0) {
            phases[activePhase].active = false;
        }
        if (phaseId > 0) {
            phases[phaseId].active = true;
        }
        activePhase = phaseId;
        emit PhaseChanged(phaseId);
    }

    // ── Minting ──────────────────────────────────────────────────────
    /**
     * @notice Mint tokens in the active phase.
     * @param quantity Number of tokens to mint.
     * @param proof    Merkle proof for whitelist (empty for public).
     */
    function mint(
        uint256 quantity,
        bytes32[] calldata proof
    ) external payable nonReentrant {
        if (quantity == 0) revert ZeroQuantity();
        _validateMintPhase();

        PhaseConfig storage phase = phases[activePhase];

        _validateWhitelist(phase, proof);
        _validateWalletLimit(phase, quantity);

        // Supply check
        if (nextTokenId + quantity > maxSupply) {
            revert MaxSupplyExceeded();
        }

        // Payment check
        uint256 totalCost = phase.price * quantity;
        if (msg.value != totalCost) revert IncorrectPayment();

        // Mint
        uint256 startId = nextTokenId;
        for (uint256 i = 0; i < quantity; ++i) {
            _safeMint(msg.sender, nextTokenId);
            ++nextTokenId;
        }
        mintedPerPhase[activePhase][msg.sender] += quantity;

        emit Minted(msg.sender, startId, quantity);
    }

    /**
     * @notice Owner-only batch mint (airdrops, reserves).
     * @dev Added nonReentrant and MAX_BATCH_SIZE (H-01 fix).
     * @param to       Recipient address.
     * @param quantity Number of tokens to mint (max 100).
     */
    function batchMint(
        address to,
        uint256 quantity
    ) external onlyOwner nonReentrant {
        if (quantity == 0) revert ZeroQuantity();
        if (quantity > MAX_BATCH_SIZE) revert BatchSizeExceeded();
        if (nextTokenId + quantity > maxSupply) {
            revert MaxSupplyExceeded();
        }

        uint256 startId = nextTokenId;
        for (uint256 i = 0; i < quantity; ++i) {
            _safeMint(to, nextTokenId);
            ++nextTokenId;
        }
        emit Minted(to, startId, quantity);
    }

    // ── Reveal ───────────────────────────────────────────────────────
    /**
     * @notice Reveal the collection by setting the real base URI.
     * @param baseURI The IPFS base URI for revealed metadata.
     */
    function reveal(string calldata baseURI) external onlyOwner {
        if (revealed) revert AlreadyRevealed();
        revealed = true;
        _revealedBaseURI = baseURI;
        emit Revealed(baseURI);
    }

    // ── Withdrawal ───────────────────────────────────────────────────
    /**
     * @notice Withdraw all contract revenue to the owner.
     */
    function withdraw() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) revert TransferFailed();

        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, ) = payable(owner).call{value: balance}("");
        if (!ok) revert TransferFailed();

        emit Withdrawn(owner, balance);
    }

    /**
     * @notice Transfer ownership of the collection.
     * @param newOwner The new owner address.
     */
    function transferOwnership(
        address newOwner
    ) external onlyOwner {
        if (newOwner == address(0)) revert TransferFailed();
        owner = newOwner;
    }

    // ── External view helpers ──────────────────────────────────────
    /**
     * @notice Total tokens minted so far.
     * @return Number of minted tokens.
     */
    function totalMinted() external view returns (uint256) {
        return nextTokenId;
    }

    /**
     * @notice Remaining mintable supply.
     * @return Tokens left to mint.
     */
    function remainingSupply() external view returns (uint256) {
        return maxSupply - nextTokenId;
    }

    // ── Name / symbol overrides (per-clone values) ───────────────────
    /**
     * @notice Returns the per-clone collection name.
     * @dev Overrides ERC721.name(). Before initialization returns
     *      the default "OmniNFT".
     * @return The collection name.
     */
    function name()
        public
        view
        override
        returns (string memory)
    {
        if (bytes(_collectionName).length > 0) {
            return _collectionName;
        }
        return super.name();
    }

    /**
     * @notice Returns the per-clone collection symbol.
     * @dev Overrides ERC721.symbol(). Before initialization returns
     *      the default "ONFT".
     * @return The collection symbol.
     */
    function symbol()
        public
        view
        override
        returns (string memory)
    {
        if (bytes(_collectionSymbol).length > 0) {
            return _collectionSymbol;
        }
        return super.symbol();
    }

    // ── URI overrides ────────────────────────────────────────────────
    /**
     * @notice Returns the token URI.
     * @dev Before reveal, returns unrevealedURI for all tokens.
     * @param tokenId Token to query.
     * @return URI string.
     */
    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (!revealed) {
            return unrevealedURI;
        }
        return string.concat(
            _revealedBaseURI,
            tokenId.toString(),
            ".json"
        );
    }

    // ── ERC-165 ──────────────────────────────────────────────────────
    /**
     * @notice Check if this contract supports a given interface.
     * @dev Supports ERC721 and ERC2981 interfaces.
     * @param interfaceId The interface identifier to check.
     * @return supported True if the interface is supported.
     */
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(ERC721, ERC2981)
        returns (bool supported)
    {
        return super.supportsInterface(interfaceId);
    }

    // ── Internal helpers ─────────────────────────────────────────────

    /**
     * @dev Validate that a minting phase is active.
     */
    function _validateMintPhase() internal view {
        if (activePhase == 0) revert PhaseNotActive();
        if (!phases[activePhase].active) revert PhaseNotActive();
    }

    /**
     * @notice Validate whitelist proof if the phase requires one.
     * @dev Reverts with InvalidProof if the proof is invalid.
     *      M-03: Merkle leaf includes block.chainid, contract address,
     *      and active phase ID to prevent cross-chain and cross-
     *      collection proof replay attacks.
     * @param phase The active phase config.
     * @param proof Merkle proof array.
     */
    function _validateWhitelist(
        PhaseConfig storage phase,
        bytes32[] calldata proof
    ) internal view {
        if (phase.merkleRoot != bytes32(0)) {
            // M-03: Include chainId, contract address, and phase in
            // the leaf to prevent cross-chain / cross-collection /
            // cross-phase proof reuse.
            bytes32 leaf = keccak256(
                abi.encodePacked(
                    block.chainid,
                    address(this),
                    activePhase,
                    msg.sender
                )
            );
            if (
                !MerkleProof.verify(
                    proof,
                    phase.merkleRoot,
                    leaf
                )
            ) {
                revert InvalidProof();
            }
        }
    }

    /**
     * @notice Validate per-wallet mint limit for the active phase.
     * @dev Reverts with WalletLimitExceeded if over limit.
     * @param phase The active phase config.
     * @param quantity Number of tokens being minted.
     */
    function _validateWalletLimit(
        PhaseConfig storage phase,
        uint256 quantity
    ) internal view {
        if (phase.maxPerWallet > 0) {
            uint256 minted =
                mintedPerPhase[activePhase][msg.sender];
            if (minted + quantity > phase.maxPerWallet) {
                revert WalletLimitExceeded();
            }
        }
    }
}
