// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OmniNFTCollection
 * @author OmniBazaar Development Team
 * @notice ERC-721 collection contract deployed via OmniNFTFactory using ERC-1167 clones.
 * @dev Supports multi-phase minting (whitelist + public), per-wallet limits,
 *      batch minting, deferred reveal, ERC-2981 royalties, and creator withdrawals.
 *      Uses an initializer instead of a constructor so the factory can clone it.
 */
contract OmniNFTCollection is ERC721, ERC2981, ReentrancyGuard {
    using Strings for uint256;

    // ── Custom errors ────────────────────────────────────────────────────
    /// @dev Thrown when a non-owner calls an owner-only function.
    error NotOwner();
    /// @dev Thrown when initialize is called more than once.
    error AlreadyInitialized();
    /// @dev Thrown when minting would exceed the collection max supply.
    error MaxSupplyExceeded();
    /// @dev Thrown when the caller exceeds their per-wallet mint limit.
    error WalletLimitExceeded();
    /// @dev Thrown when the wrong ETH value is sent for minting.
    error IncorrectPayment();
    /// @dev Thrown when minting is attempted while the phase is inactive.
    error PhaseNotActive();
    /// @dev Thrown when a whitelist proof is invalid.
    error InvalidProof();
    /// @dev Thrown when a quantity of zero is passed.
    error ZeroQuantity();
    /// @dev Thrown when the royalty basis points exceed 25%.
    error RoyaltyTooHigh();
    /// @dev Thrown when an ETH transfer fails.
    error TransferFailed();
    /// @dev Thrown when the collection has already been revealed.
    error AlreadyRevealed();
    /// @dev Thrown when the phase has already been set to the requested value.
    error PhaseAlreadySet();

    // ── Events ───────────────────────────────────────────────────────────
    /// @notice Emitted when one or more tokens are minted.
    event Minted(address indexed to, uint256 startTokenId, uint256 quantity);
    /// @notice Emitted when the collection metadata is revealed.
    event Revealed(string baseURI);
    /// @notice Emitted when the active phase changes.
    event PhaseChanged(uint8 indexed phaseId);
    /// @notice Emitted when the creator withdraws revenue.
    event Withdrawn(address indexed to, uint256 amount);

    // ── Constants ────────────────────────────────────────────────────────
    /// @notice Maximum royalty: 25 % (2500 basis points).
    uint16 public constant MAX_ROYALTY_BPS = 2500;

    // ── Storage ──────────────────────────────────────────────────────────
    /// @notice Collection owner / creator address.
    address public owner;
    /// @notice Whether the contract has been initialized via the factory.
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

    /// @notice Currently active minting phase (0 = paused).
    uint8 public activePhase;

    /**
     * @notice Configuration for a single minting phase.
     * @param price Mint price in wei per token.
     * @param maxPerWallet Maximum tokens a single wallet may mint in this phase.
     * @param merkleRoot Merkle root for whitelist verification (bytes32(0) = public).
     * @param active Whether this phase is currently accepting mints.
     */
    struct PhaseConfig {
        uint256 price;
        uint16 maxPerWallet;
        bytes32 merkleRoot;
        bool active;
    }

    /// @notice Phase configs keyed by phase ID (1-indexed).
    mapping(uint8 => PhaseConfig) public phases;
    /// @notice Number of configured phases.
    uint8 public phaseCount;
    /// @notice Per-wallet mint counts per phase: phase => wallet => count.
    mapping(uint8 => mapping(address => uint256)) public mintedPerPhase;

    // ── Modifiers ────────────────────────────────────────────────────────
    /// @dev Restricts to the collection owner.
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ── Constructor (disabled for clone pattern) ─────────────────────────
    /**
     * @dev Constructor is only used to set the ERC721 name/symbol for the
     *      implementation contract. Clones call `initialize()` instead.
     */
    constructor() ERC721("OmniNFT", "ONFT") {
        // Mark the implementation as initialized so it cannot be re-used
        initialized = true;
    }

    // ── Initializer ──────────────────────────────────────────────────────
    /**
     * @notice Initialize a freshly cloned collection. Called once by the factory.
     * @param _owner         Creator / owner address.
     * @param _name          Collection name (stored off-chain; ERC721 name set at deploy).
     * @param _symbol        Collection symbol (stored off-chain).
     * @param _maxSupply     Maximum mintable tokens.
     * @param _royaltyBps    Royalty in basis points (0-2500).
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

        if (_royaltyBps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();

        owner = _owner;
        maxSupply = _maxSupply;
        unrevealedURI = _unrevealedURI;

        // ERC-2981 default royalty
        if (_royaltyBps > 0 && _royaltyRecipient != address(0)) {
            _setDefaultRoyalty(_royaltyRecipient, _royaltyBps);
        }

        // Note: ERC721 name/symbol are set in the constructor and cannot
        // be changed in a clone. The factory emits name/symbol in the event
        // and off-chain indexers use those values.
        // Suppress unused parameter warnings:
        _name;
        _symbol;
    }

    // ── Phase management ─────────────────────────────────────────────────
    /**
     * @notice Configure a minting phase.
     * @param phaseId       Phase identifier (1-indexed).
     * @param price         Price per mint in wei.
     * @param maxPerWallet  Max mints per wallet in this phase.
     * @param merkleRoot    Merkle root for whitelist (bytes32(0) for public).
     */
    function setPhase(
        uint8 phaseId,
        uint256 price,
        uint16 maxPerWallet,
        bytes32 merkleRoot
    ) external onlyOwner {
        if (phaseId == 0) revert ZeroQuantity();
        phases[phaseId] = PhaseConfig({
            price: price,
            maxPerWallet: maxPerWallet,
            merkleRoot: merkleRoot,
            active: false
        });
        if (phaseId > phaseCount) {
            phaseCount = phaseId;
        }
    }

    /**
     * @notice Activate a specific phase and deactivate the previous one.
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

    // ── Minting ──────────────────────────────────────────────────────────
    /**
     * @notice Mint tokens in the active phase.
     * @param quantity Number of tokens to mint.
     * @param proof    Merkle proof for whitelist phases (empty for public).
     */
    function mint(uint256 quantity, bytes32[] calldata proof) external payable nonReentrant {
        if (quantity == 0) revert ZeroQuantity();
        if (activePhase == 0) revert PhaseNotActive();

        PhaseConfig storage phase = phases[activePhase];
        if (!phase.active) revert PhaseNotActive();

        // Whitelist check
        if (phase.merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
            if (!MerkleProof.verify(proof, phase.merkleRoot, leaf)) {
                revert InvalidProof();
            }
        }

        // Per-wallet limit
        if (phase.maxPerWallet > 0) {
            if (mintedPerPhase[activePhase][msg.sender] + quantity > phase.maxPerWallet) {
                revert WalletLimitExceeded();
            }
        }

        // Supply check
        if (nextTokenId + quantity > maxSupply) revert MaxSupplyExceeded();

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
     * @param to       Recipient address.
     * @param quantity Number of tokens to mint.
     */
    function batchMint(address to, uint256 quantity) external onlyOwner {
        if (quantity == 0) revert ZeroQuantity();
        if (nextTokenId + quantity > maxSupply) revert MaxSupplyExceeded();

        uint256 startId = nextTokenId;
        for (uint256 i = 0; i < quantity; ++i) {
            _safeMint(to, nextTokenId);
            ++nextTokenId;
        }
        emit Minted(to, startId, quantity);
    }

    // ── Reveal ───────────────────────────────────────────────────────────
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

    // ── Withdrawal ───────────────────────────────────────────────────────
    /**
     * @notice Withdraw all contract revenue to the owner.
     */
    function withdraw() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) revert TransferFailed();

        (bool ok, ) = payable(owner).call{value: balance}("");
        if (!ok) revert TransferFailed();

        emit Withdrawn(owner, balance);
    }

    /**
     * @notice Transfer ownership of the collection.
     * @param newOwner The new owner address.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert TransferFailed();
        owner = newOwner;
    }

    // ── URI overrides ────────────────────────────────────────────────────
    /**
     * @notice Returns the token URI. Before reveal, returns unrevealedURI for all tokens.
     * @param tokenId Token to query.
     * @return URI string.
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (!revealed) {
            return unrevealedURI;
        }
        return string.concat(_revealedBaseURI, tokenId.toString(), ".json");
    }

    // ── View helpers ─────────────────────────────────────────────────────
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

    // ── ERC-165 ──────────────────────────────────────────────────────────
    /**
     * @dev Supports ERC721 and ERC2981 interfaces.
     */
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
