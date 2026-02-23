// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/**
 * @title ReputationCredential
 * @author OmniBazaar Development Team
 * @notice Soulbound ERC-721 representing a user's portable reputation credential.
 * @dev Non-transferable (ERC-5192 compliant). Each user can hold at most one token.
 *      On-chain metadata allows any dApp to verify a user's marketplace reputation
 *      without trusting OmniBazaar infrastructure.
 *
 *      Token fields stored on-chain:
 *      - totalTransactions: completed buy/sell transactions
 *      - averageRating: scaled x100 (e.g., 450 = 4.50 stars)
 *      - accountAgeDays: days since account creation
 *      - kycTier: verification level (0-4)
 *      - disputeWins / disputeLosses: arbitration record
 *      - participationScore: 0-100 Proof of Participation score
 *
 *      Audit Fixes (2026-02-22):
 *      - M-01: Bounds validation on reputation data fields
 *      - M-02: Two-step updater transfer (key rotation)
 *      - L-01: CEI pattern in mint() (state before callback)
 *      - L-02: Zero-address check in constructor
 */
contract ReputationCredential is ERC721 {
    using Strings for uint256;

    // ── Structs ────────────────────────────────────────────────────────
    /// @notice On-chain reputation data for a single user.
    struct ReputationData {
        uint32 totalTransactions;
        uint16 averageRating;      // x100 scale (0-500)
        uint16 accountAgeDays;
        uint8  kycTier;            // 0-4
        uint16 disputeWins;
        uint16 disputeLosses;
        uint16 participationScore; // 0-100
        uint64 lastUpdated;        // block.timestamp of last update
    }

    // ── State ──────────────────────────────────────────────────────────
    /// @notice Address authorized to mint and update reputation data.
    /// @dev Mutable to allow key rotation via two-step transfer
    ///      pattern (M-02 fix). Previously immutable.
    address public authorizedUpdater;

    /// @notice Proposed new updater address (M-02 two-step transfer).
    /// @dev Set by transferUpdater(), accepted by acceptUpdater().
    address public pendingUpdater;

    /// @dev Auto-incrementing token ID counter.
    uint256 private _nextTokenId;

    /// @dev tokenId to ReputationData.
    mapping(uint256 => ReputationData) private _reputation;

    /// @dev userAddress to tokenId (0 means no token).
    mapping(address => uint256) private _userToken;

    // ── Events ─────────────────────────────────────────────────────────
    /// @notice ERC-5192: Emitted when a token is permanently locked.
    /// @param tokenId The token that was locked.
    event Locked(uint256 indexed tokenId);

    /// @notice Emitted when reputation data is updated on-chain.
    /// @param tokenId Token whose reputation was updated.
    /// @param participationScore New participation score (0-100).
    event ReputationUpdated(
        uint256 indexed tokenId,
        uint16 participationScore
    );

    /// @notice Emitted when an updater transfer is proposed (M-02).
    /// @param currentUpdater The current authorized updater.
    /// @param proposedUpdater The proposed new updater.
    event UpdaterTransferProposed(
        address indexed currentUpdater,
        address indexed proposedUpdater
    );

    /// @notice Emitted when an updater transfer is accepted (M-02).
    /// @param previousUpdater The previous authorized updater.
    /// @param newUpdater The new authorized updater.
    event UpdaterTransferred(
        address indexed previousUpdater,
        address indexed newUpdater
    );

    // ── Custom errors ──────────────────────────────────────────────────
    /// @dev Caller is not the authorized updater.
    error NotAuthorized();
    /// @dev Soulbound tokens cannot be transferred.
    error Soulbound();
    /// @dev User already holds a reputation token.
    error AlreadyMinted();
    /// @dev Token does not exist.
    error TokenNotFound();
    /// @dev Average rating exceeds maximum (500 = 5.00 stars).
    error InvalidRating(uint16 rating);
    /// @dev KYC tier exceeds maximum (4).
    error InvalidKYCTier(uint8 tier);
    /// @dev Participation score exceeds maximum (100).
    error InvalidScore(uint16 score);
    /// @dev Zero address provided.
    error ZeroAddress();

    // ── Modifiers ──────────────────────────────────────────────────────
    /// @dev Restrict to authorized updater only.
    modifier onlyUpdater() {
        if (msg.sender != authorizedUpdater) {
            revert NotAuthorized();
        }
        _;
    }

    // ── Constructor ────────────────────────────────────────────────────
    /**
     * @notice Deploy the ReputationCredential contract.
     * @param _authorizedUpdater Address allowed to mint and update
     *        (validator deployer key or multisig).
     */
    constructor(
        address _authorizedUpdater
    ) ERC721("OmniBazaar Reputation", "OMNI-REP") {
        if (_authorizedUpdater == address(0)) {
            revert ZeroAddress();
        }
        authorizedUpdater = _authorizedUpdater;
        _nextTokenId = 1; // Start at 1 so 0 means "no token"
    }

    // ── External mutating functions ─────────────────────────────────────

    // ── Updater transfer (M-02) ────────────────────────────────────────
    /**
     * @notice Propose a new authorized updater (two-step transfer).
     * @dev Only the current updater can propose. The proposed updater
     *      must call acceptUpdater() to complete the transfer.
     * @param newUpdater Address of the proposed new updater.
     */
    function transferUpdater(
        address newUpdater
    ) external onlyUpdater {
        if (newUpdater == address(0)) revert ZeroAddress();
        pendingUpdater = newUpdater;
        emit UpdaterTransferProposed(
            authorizedUpdater, newUpdater
        );
    }

    /**
     * @notice Accept the updater role (two-step transfer).
     * @dev Only the pending updater can accept. Completes the
     *      transfer and clears the pending state.
     */
    function acceptUpdater() external {
        if (msg.sender != pendingUpdater) {
            revert NotAuthorized();
        }
        address previous = authorizedUpdater;
        authorizedUpdater = msg.sender;
        pendingUpdater = address(0);
        emit UpdaterTransferred(previous, msg.sender);
    }

    // ── Mint ───────────────────────────────────────────────────────────
    /**
     * @notice Mint a reputation NFT for a user.
     * @dev Only one token per user. Emits Locked per ERC-5192.
     *      Validates reputation data bounds (M-01).
     * @param user The wallet address to receive the token.
     * @param data Initial reputation data.
     */
    function mint(
        address user,
        ReputationData calldata data
    ) external onlyUpdater {
        if (_userToken[user] != 0) revert AlreadyMinted();
        _validateReputation(data);

        uint256 tokenId = _nextTokenId;
        _nextTokenId = tokenId + 1;

        // CEI: Set state before external call (L-01 fix)
        _reputation[tokenId] = data;
        // solhint-disable not-rely-on-time
        _reputation[tokenId].lastUpdated =
            uint64(block.timestamp);
        // solhint-enable not-rely-on-time
        _userToken[user] = tokenId;

        _safeMint(user, tokenId);

        emit Locked(tokenId);
        emit ReputationUpdated(
            tokenId, data.participationScore
        );
    }

    // ── Update ─────────────────────────────────────────────────────────
    /**
     * @notice Update reputation data for an existing token.
     * @dev Validates reputation data bounds (M-01).
     * @param user The user whose reputation is being updated.
     * @param data New reputation data.
     */
    function updateReputation(
        address user,
        ReputationData calldata data
    ) external onlyUpdater {
        uint256 tokenId = _userToken[user];
        if (tokenId == 0) revert TokenNotFound();
        _validateReputation(data);

        _reputation[tokenId] = data;
        // solhint-disable not-rely-on-time
        _reputation[tokenId].lastUpdated =
            uint64(block.timestamp);
        // solhint-enable not-rely-on-time

        emit ReputationUpdated(
            tokenId, data.participationScore
        );
    }

    // ── External view functions ─────────────────────────────────────────

    // ── ERC-5192: Soulbound ────────────────────────────────────────────
    /**
     * @notice All tokens are permanently locked (soulbound).
     * @param tokenId The token to check.
     * @return True (always locked).
     */
    function locked(uint256 tokenId) external view returns (bool) {
        if (_ownerOf(tokenId) == address(0)) revert TokenNotFound();
        return true;
    }

    /**
     * @notice Get reputation data for a user.
     * @param user The wallet address to query.
     * @return data The reputation data struct.
     */
    function getReputation(
        address user
    ) external view returns (ReputationData memory data) {
        uint256 tokenId = _userToken[user];
        if (tokenId == 0) revert TokenNotFound();
        return _reputation[tokenId];
    }

    /**
     * @notice Get the token ID for a user.
     * @param user The wallet address to query.
     * @return tokenId The token ID (0 if none).
     */
    function getTokenId(address user) external view returns (uint256) {
        return _userToken[user];
    }

    /**
     * @notice Check whether a user has a reputation token.
     * @param user The wallet address to check.
     * @return True if the user has a minted token.
     */
    function hasReputation(address user) external view returns (bool) {
        return _userToken[user] != 0;
    }

    // ── Public functions ────────────────────────────────────────────────

    // ── On-chain metadata ──────────────────────────────────────────────
    /**
     * @notice Returns on-chain JSON metadata for the token.
     * @param tokenId The token to query.
     * @return A data URI with base64-encoded JSON metadata.
     */
    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert TokenNotFound();

        ReputationData memory rep = _reputation[tokenId];

        // solhint-disable quotes
        string memory json = string(
            abi.encodePacked(
                '{"name":"OmniBazaar Reputation #',
                tokenId.toString(),
                '","description":"Soulbound reputation credential from OmniBazaar marketplace"',
                ',"attributes":[',
                _attr("Total Transactions", rep.totalTransactions),
                ",",
                _attr("Average Rating", rep.averageRating),
                ",",
                _attr("Account Age (days)", rep.accountAgeDays),
                ",",
                _attr("KYC Tier", rep.kycTier),
                ",",
                _attr("Dispute Wins", rep.disputeWins),
                ",",
                _attr("Dispute Losses", rep.disputeLosses),
                ",",
                _attr("Participation Score", rep.participationScore),
                "]}"
            )
        );
        // solhint-enable quotes

        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(bytes(json))
            )
        );
    }

    /**
     * @notice ERC-165 interface detection.
     * @param interfaceId The interface identifier.
     * @return True if supported.
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        // ERC-5192 interface ID: 0xb45a3c0e
        return
            interfaceId == 0xb45a3c0e ||
            super.supportsInterface(interfaceId);
    }

    // ── Internal functions ──────────────────────────────────────────────

    // ── Transfer blocking (soulbound) ──────────────────────────────────
    /**
     * @notice Override _update to block all transfers except minting.
     * @dev Soulbound tokens can only be minted, never transferred.
     * @param to Recipient address.
     * @param tokenId Token being transferred.
     * @param auth Address authorized for the transfer.
     * @return The previous owner.
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);
        // Allow minting (from == address(0)), block all transfers
        if (from != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    // ── Private functions ───────────────────────────────────────────────

    /**
     * @notice Build a single ERC-721 metadata attribute JSON fragment.
     * @param traitType The attribute name.
     * @param value The numeric value.
     * @return JSON string fragment.
     */
    function _attr(
        string memory traitType,
        uint256 value
    ) private pure returns (string memory) {
        // solhint-disable quotes
        return string(
            abi.encodePacked(
                '{"trait_type":"',
                traitType,
                '","value":',
                value.toString(),
                "}"
            )
        );
        // solhint-enable quotes
    }

    // ── Internal validation ─────────────────────────────────────────
    /**
     * @notice Validate reputation data field bounds (M-01).
     * @dev Ensures on-chain enforcement of documented ranges:
     *      - averageRating: 0-500 (x100 scale, max 5.00 stars)
     *      - kycTier: 0-4 (five KYC levels)
     *      - participationScore: 0-100 (percentage)
     * @param data ReputationData to validate.
     */
    function _validateReputation(
        ReputationData calldata data
    ) private pure {
        if (data.averageRating > 500) {
            revert InvalidRating(data.averageRating);
        }
        if (data.kycTier > 4) {
            revert InvalidKYCTier(data.kycTier);
        }
        if (data.participationScore > 100) {
            revert InvalidScore(data.participationScore);
        }
    }
}
