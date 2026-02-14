// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Holder} from
    "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FractionToken} from "./FractionToken.sol";

/**
 * @title OmniFractionalNFT
 * @author OmniBazaar Development Team
 * @notice Vault that locks NFTs and issues ERC-20 fraction tokens.
 * @dev Owner locks an NFT, receives `totalShares` ERC-20 tokens.
 *      A holder of 100 % of shares can redeem (burn all, get NFT).
 *      Buyout mechanism lets any share-holder propose a buyout price;
 *      once funded, remaining share-holders can claim their pro-rata share.
 *      1 % creation fee sent to the platform fee recipient.
 */
contract OmniFractionalNFT is ERC721Holder, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ── Custom errors ────────────────────────────────────────────────────
    /// @dev Fraction vault not found.
    error VaultNotFound();
    /// @dev Vault is not active (already redeemed or bought out).
    error VaultNotActive();
    /// @dev Caller does not hold 100 % of fraction tokens.
    error InsufficientShares();
    /// @dev Total shares must be > 1.
    error InvalidShareCount();
    /// @dev Buyout already in progress or executed.
    error BuyoutAlreadyActive();
    /// @dev No buyout proposal exists.
    error NoBuyoutProposal();
    /// @dev Buyout price is zero.
    error ZeroBuyoutPrice();
    /// @dev Platform fee exceeds maximum.
    error FeeTooHigh();

    // ── Events ───────────────────────────────────────────────────────────
    /// @notice Emitted when an NFT is fractionalized.
    /// @param vaultId Vault identifier.
    /// @param owner Original NFT owner.
    /// @param collection NFT collection address.
    /// @param tokenId NFT token ID.
    /// @param fractionToken Deployed ERC-20 token address.
    /// @param totalShares Number of fraction shares minted.
    event Fractionalized(
        uint256 indexed vaultId,
        address indexed owner,
        address indexed collection,
        uint256 tokenId,
        address fractionToken,
        uint256 totalShares
    );

    /// @notice Emitted when a vault is redeemed by a 100 % holder.
    /// @param vaultId Vault that was redeemed.
    /// @param redeemer Address that redeemed.
    event Redeemed(uint256 indexed vaultId, address indexed redeemer);

    /// @notice Emitted when a buyout is proposed.
    /// @param vaultId Target vault.
    /// @param proposer Address proposing the buyout.
    /// @param totalPrice Total buyout price in payment currency.
    event BuyoutProposed(
        uint256 indexed vaultId,
        address indexed proposer,
        uint256 totalPrice
    );

    /// @notice Emitted when a buyout is executed.
    /// @param vaultId Bought-out vault.
    /// @param buyer Buyer who funded the buyout.
    event BuyoutExecuted(uint256 indexed vaultId, address indexed buyer);

    // ── Constants ────────────────────────────────────────────────────────
    /// @notice Basis points denominator.
    uint16 public constant BPS_DENOMINATOR = 10000;
    /// @notice Maximum creation fee: 5 % (500 bps).
    uint16 public constant MAX_CREATION_FEE_BPS = 500;

    // ── Structs ──────────────────────────────────────────────────────────
    /// @notice State for a fractionalized NFT vault.
    struct Vault {
        address owner;
        address collection;
        uint256 tokenId;
        address fractionToken;
        uint256 totalShares;
        bool active;
        bool boughtOut;
        address buyoutProposer;
        uint256 buyoutPrice;
        address buyoutCurrency;
    }

    // ── Storage ──────────────────────────────────────────────────────────
    /// @notice Platform creation fee in basis points (default 1 % = 100 bps).
    uint16 public creationFeeBps;
    /// @notice Address receiving platform fees.
    address public feeRecipient;
    /// @notice Payment currency for creation fees (address(0) = native token).
    address public feeCurrency;
    /// @notice Next vault ID.
    uint256 public nextVaultId;
    /// @notice Vault by ID.
    mapping(uint256 => Vault) public vaults;
    /// @notice Lookup vault by NFT (collection => tokenId => vaultId).
    mapping(address => mapping(uint256 => uint256)) public nftToVault;

    // ── Constructor ──────────────────────────────────────────────────────
    /**
     * @notice Deploy the fractionalization vault.
     * @param initialFeeRecipient Platform fee recipient.
     * @param initialFeeBps Creation fee in basis points (e.g. 100 = 1 %).
     */
    constructor(
        address initialFeeRecipient,
        uint16 initialFeeBps
    ) Ownable(msg.sender) {
        if (initialFeeBps > MAX_CREATION_FEE_BPS) revert FeeTooHigh();
        feeRecipient = initialFeeRecipient;
        creationFeeBps = initialFeeBps;
    }

    // ── External functions ───────────────────────────────────────────────

    /**
     * @notice Lock an NFT and create ERC-20 fraction tokens.
     * @param collection NFT collection address.
     * @param tokenId Token ID to fractionalize.
     * @param totalShares Number of ERC-20 shares to mint (must be > 1).
     * @param name ERC-20 name for the fraction token.
     * @param symbol ERC-20 symbol for the fraction token.
     * @return vaultId The new vault identifier.
     */
    function fractionalize(
        address collection,
        uint256 tokenId,
        uint256 totalShares,
        string calldata name,
        string calldata symbol
    ) external nonReentrant returns (uint256 vaultId) {
        if (totalShares <= 1) revert InvalidShareCount();

        vaultId = nextVaultId++;

        // Deploy fraction token — mints all shares to msg.sender
        FractionToken token = new FractionToken(
            name,
            symbol,
            address(this),
            msg.sender,
            totalShares
        );

        vaults[vaultId] = Vault({
            owner: msg.sender,
            collection: collection,
            tokenId: tokenId,
            fractionToken: address(token),
            totalShares: totalShares,
            active: true,
            boughtOut: false,
            buyoutProposer: address(0),
            buyoutPrice: 0,
            buyoutCurrency: address(0)
        });

        nftToVault[collection][tokenId] = vaultId;

        // Lock NFT in vault
        IERC721(collection).safeTransferFrom(
            msg.sender,
            address(this),
            tokenId
        );

        emit Fractionalized(
            vaultId,
            msg.sender,
            collection,
            tokenId,
            address(token),
            totalShares
        );
    }

    /**
     * @notice Redeem an NFT by burning 100 % of fraction tokens.
     * @param vaultId The vault to redeem.
     */
    function redeem(uint256 vaultId) external nonReentrant {
        Vault storage v = vaults[vaultId];
        if (v.owner == address(0)) revert VaultNotFound();
        if (!v.active) revert VaultNotActive();

        FractionToken token = FractionToken(v.fractionToken);
        uint256 balance = token.balanceOf(msg.sender);
        if (balance < v.totalShares) revert InsufficientShares();

        v.active = false;

        // Burn all shares
        token.burnFrom(msg.sender, v.totalShares);

        // Return NFT
        IERC721(v.collection).safeTransferFrom(
            address(this),
            msg.sender,
            v.tokenId
        );

        emit Redeemed(vaultId, msg.sender);
    }

    /**
     * @notice Propose a buyout for a fractionalized NFT.
     * @dev Proposer must deposit `totalPrice` in `currency`. Other holders
     *      can later claim their pro-rata share by burning their tokens.
     * @param vaultId Vault to buy out.
     * @param totalPrice Total price offered for 100 % of shares.
     * @param currency ERC-20 payment token.
     */
    function proposeBuyout(
        uint256 vaultId,
        uint256 totalPrice,
        address currency
    ) external nonReentrant {
        Vault storage v = vaults[vaultId];
        if (v.owner == address(0)) revert VaultNotFound();
        if (!v.active) revert VaultNotActive();
        if (v.buyoutProposer != address(0)) revert BuyoutAlreadyActive();
        if (totalPrice == 0) revert ZeroBuyoutPrice();

        v.buyoutProposer = msg.sender;
        v.buyoutPrice = totalPrice;
        v.buyoutCurrency = currency;

        // Deposit buyout funds
        IERC20(currency).safeTransferFrom(
            msg.sender,
            address(this),
            totalPrice
        );

        emit BuyoutProposed(vaultId, msg.sender, totalPrice);
    }

    /**
     * @notice Execute a buyout: burn shares to claim pro-rata payment.
     * @dev Any share-holder can call this to sell their shares at the
     *      buyout price. When all shares are burned, NFT goes to proposer.
     * @param vaultId Vault with active buyout.
     * @param sharesToSell Number of shares to sell.
     */
    function executeBuyout(
        uint256 vaultId,
        uint256 sharesToSell
    ) external nonReentrant {
        Vault storage v = vaults[vaultId];
        if (v.owner == address(0)) revert VaultNotFound();
        if (!v.active) revert VaultNotActive();
        if (v.buyoutProposer == address(0)) revert NoBuyoutProposal();

        FractionToken token = FractionToken(v.fractionToken);
        uint256 balance = token.balanceOf(msg.sender);
        if (balance < sharesToSell) revert InsufficientShares();

        // Calculate pro-rata payment
        uint256 payment = (v.buyoutPrice * sharesToSell) / v.totalShares;

        // Burn shares
        token.burnFrom(msg.sender, sharesToSell);

        // Pay seller
        IERC20(v.buyoutCurrency).safeTransfer(msg.sender, payment);

        // If all shares burned, transfer NFT to proposer
        if (token.totalSupply() == 0) {
            v.active = false;
            v.boughtOut = true;

            IERC721(v.collection).safeTransferFrom(
                address(this),
                v.buyoutProposer,
                v.tokenId
            );

            emit BuyoutExecuted(vaultId, v.buyoutProposer);
        }
    }

    // ── Admin functions ──────────────────────────────────────────────────

    /**
     * @notice Update the creation fee.
     * @param newFeeBps New fee in basis points.
     */
    function setCreationFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_CREATION_FEE_BPS) revert FeeTooHigh();
        creationFeeBps = newFeeBps;
    }

    /**
     * @notice Update the fee recipient.
     * @param newRecipient New recipient address.
     */
    function setFeeRecipient(address newRecipient) external onlyOwner {
        feeRecipient = newRecipient;
    }

    // ── View functions ───────────────────────────────────────────────────

    /**
     * @notice Get vault details.
     * @param vaultId The vault to query.
     * @return owner Original NFT owner.
     * @return collection NFT collection.
     * @return tokenId NFT token ID.
     * @return fractionToken ERC-20 fraction token address.
     * @return totalShares Total shares minted.
     * @return active Whether the vault is active.
     * @return boughtOut Whether the vault was bought out.
     */
    function getVault(uint256 vaultId)
        external
        view
        returns (
            address owner,
            address collection,
            uint256 tokenId,
            address fractionToken,
            uint256 totalShares,
            bool active,
            bool boughtOut
        )
    {
        Vault storage v = vaults[vaultId];
        return (
            v.owner,
            v.collection,
            v.tokenId,
            v.fractionToken,
            v.totalShares,
            v.active,
            v.boughtOut
        );
    }

    /**
     * @notice Look up vault ID by NFT.
     * @param collection NFT collection.
     * @param tokenId NFT token ID.
     * @return vaultId The vault ID (0 if not fractionalized).
     */
    function getVaultByNFT(
        address collection,
        uint256 tokenId
    ) external view returns (uint256 vaultId) {
        return nftToVault[collection][tokenId];
    }
}
