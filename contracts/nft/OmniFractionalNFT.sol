// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Holder} from
    "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from
    "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from
    "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC2771Context} from
    "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from
    "@openzeppelin/contracts/utils/Context.sol";

/**
 * @title FractionToken
 * @author OmniBazaar Development Team
 * @notice Minimal ERC-20 representing fractional ownership of a locked NFT.
 * @dev Deployed by OmniFractionalNFT when an NFT is fractionalized.
 *      Only the vault contract may burn tokens so that the invariant
 *      totalSupply == VAULT.totalShares is preserved until an explicit
 *      redeem or buyout operation (C-01 audit fix).
 */
contract FractionToken is ERC20, ERC20Burnable {
    /// @notice Address of the OmniFractionalNFT vault that created this token.
    address public immutable VAULT;

    /// @dev Caller is not the vault contract.
    error OnlyVault();

    /**
     * @notice Deploy a new fraction token.
     * @param tokenName ERC-20 name.
     * @param tokenSymbol ERC-20 symbol.
     * @param vaultAddress OmniFractionalNFT contract address.
     * @param initialHolder Address to receive initial supply.
     * @param totalShares Total number of fractional shares to mint.
     */
    constructor(
        string memory tokenName,
        string memory tokenSymbol,
        address vaultAddress,
        address initialHolder,
        uint256 totalShares
    ) ERC20(tokenName, tokenSymbol) {
        VAULT = vaultAddress;
        _mint(initialHolder, totalShares);
    }

    // ── External functions ─────────────────────────────────────────────

    /**
     * @notice Burn tokens from an account without requiring ERC-20
     *         allowance -- restricted to vault only.
     * @dev M-03: Allows the vault to burn share tokens during redeem()
     *      and executeBuyout() without the holder needing to call
     *      approve() first. This improves UX by eliminating the extra
     *      approval transaction while maintaining the same security
     *      guarantee (only the vault can call this).
     * @param account Account whose tokens will be burned.
     * @param amount Amount of tokens to burn.
     */
    function vaultBurn(address account, uint256 amount) external {
        if (msg.sender != VAULT) revert OnlyVault();
        _burn(account, amount);
    }

    // ── Public functions (overrides) ──────────────────────────────────

    /**
     * @notice Burn tokens from the caller -- restricted to vault only.
     * @dev Overrides ERC20Burnable.burn() to prevent arbitrary burns
     *      that would break the totalSupply == totalShares invariant.
     * @param amount Amount of tokens to burn.
     */
    function burn(uint256 amount) public override {
        if (msg.sender != VAULT) revert OnlyVault();
        super.burn(amount);
    }

    /**
     * @notice Burn tokens from an account -- restricted to vault only.
     * @dev Overrides ERC20Burnable.burnFrom(). The vault calls this
     *      during redeem() and executeBuyout() in OmniFractionalNFT.
     *      Requires prior ERC-20 approval from account to vault.
     * @param account Account whose tokens will be burned.
     * @param amount Amount of tokens to burn.
     */
    function burnFrom(address account, uint256 amount) public override {
        if (msg.sender != VAULT) revert OnlyVault();
        super.burnFrom(account, amount);
    }
}

/**
 * @title OmniFractionalNFT
 * @author OmniBazaar Development Team
 * @notice Vault that locks NFTs and issues ERC-20 fraction tokens.
 * @dev Owner locks an NFT, receives `totalShares` ERC-20 tokens.
 *      A holder of 100 % of shares can redeem (burn all, get NFT).
 *      Buyout mechanism lets any share-holder propose a buyout price;
 *      once funded, remaining share-holders can claim their pro-rata
 *      share. Platform creation fee sent to the UnifiedFeeVault for
 *      70/20/10 distribution.
 */
contract OmniFractionalNFT is
    ERC721Holder,
    ReentrancyGuard,
    Ownable2Step,
    ERC2771Context
{
    using SafeERC20 for IERC20;

    // ── Structs ──────────────────────────────────────────────────────
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
        uint256 buyoutDeadline;
    }

    // ── Constants ────────────────────────────────────────────────────
    /// @notice Basis points denominator.
    uint16 public constant BPS_DENOMINATOR = 10000;
    /// @notice Maximum creation fee: 5 % (500 bps).
    uint16 public constant MAX_CREATION_FEE_BPS = 500;
    /// @notice Buyout proposals expire after 30 days.
    uint256 public constant BUYOUT_DEADLINE_DURATION = 30 days;
    /// @notice Minimum share holding (25 %) to propose a buyout.
    uint16 public constant MIN_PROPOSER_SHARE_BPS = 2500;

    // ── Storage ──────────────────────────────────────────────────────
    /// @notice Platform creation fee in bps (default 1 % = 100 bps).
    uint16 public creationFeeBps;
    /// @notice UnifiedFeeVault address -- receives 100% of creation fees for 70/20/10 distribution.
    address public feeVault;
    /// @notice Payment currency for creation fees.
    address public feeCurrency;
    /// @notice Next vault ID.
    /// @dev M-04: Starts at 1 to avoid ambiguity with default mapping
    ///      value (0). nftToVault returning 0 now unambiguously means
    ///      "not fractionalized".
    uint256 public nextVaultId = 1;
    /// @notice Vault by ID.
    mapping(uint256 => Vault) public vaults;
    /// @notice Lookup vault by NFT (collection => tokenId => vaultId).
    mapping(address => mapping(uint256 => uint256))
        public nftToVault;

    // ── Events ───────────────────────────────────────────────────────
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
    event Redeemed(
        uint256 indexed vaultId,
        address indexed redeemer
    );

    /// @notice Emitted when a buyout is proposed.
    /// @param vaultId Target vault.
    /// @param proposer Address proposing the buyout.
    /// @param totalPrice Total buyout price in payment currency.
    event BuyoutProposed(
        uint256 indexed vaultId,
        address indexed proposer,
        uint256 indexed totalPrice
    );

    /// @notice Emitted when a buyout is executed.
    /// @param vaultId Bought-out vault.
    /// @param buyer Buyer who funded the buyout.
    event BuyoutExecuted(
        uint256 indexed vaultId,
        address indexed buyer
    );

    /// @notice Emitted when a buyout proposal is cancelled.
    /// @param vaultId Vault whose buyout was cancelled.
    /// @param proposer Address that cancelled and received refund.
    /// @param refundedAmount Amount of tokens refunded.
    event BuyoutCancelled(
        uint256 indexed vaultId,
        address indexed proposer,
        uint256 indexed refundedAmount
    );

    // ── Custom errors ────────────────────────────────────────────────
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
    /// @dev Caller is not the buyout proposer.
    error NotProposer();
    /// @dev Buyout deadline has not yet passed; cannot cancel.
    error BuyoutStillActive();
    /// @dev Buyout has expired; deadline has passed.
    error BuyoutExpired();
    /// @dev Proposer does not hold the minimum required shares.
    error InsufficientProposerShares();
    /// @dev Proposer cannot sell shares to themselves.
    error ProposerCannotSellToSelf();
    /// @dev Zero payment after rounding; share amount too small.
    error PaymentTooSmall();
    /// @dev Address is the zero address.
    error ZeroAddress();

    // ── Constructor ──────────────────────────────────────────────────
    /**
     * @notice Deploy the fractionalization vault.
     * @param initialFeeVault UnifiedFeeVault address -- receives 100% of creation fees
     *        for 70/20/10 distribution.
     * @param initialFeeBps Fee in basis points (e.g. 100 = 1 %).
     * @param trustedForwarder_ Trusted ERC-2771 forwarder address.
     */
    constructor(
        address initialFeeVault,
        uint16 initialFeeBps,
        address trustedForwarder_
    ) Ownable(msg.sender) ERC2771Context(trustedForwarder_) {
        // NFTSuite M-04: Validate fee vault is non-zero
        if (initialFeeVault == address(0)) revert ZeroAddress();
        if (initialFeeBps > MAX_CREATION_FEE_BPS) revert FeeTooHigh();
        feeVault = initialFeeVault;
        creationFeeBps = initialFeeBps;
    }

    // ── External functions ───────────────────────────────────────────

    /**
     * @notice Lock an NFT and create ERC-20 fraction tokens.
     * @dev Audit M-02: The creation fee is denominated in `feeCurrency`
     *      and calculated as `totalShares * creationFeeBps / 10000`.
     *      This is intentionally share-based (not NFT-value-based) to
     *      discourage excessive fractionalization. Creators choosing
     *      fewer shares pay proportionally less. The fee is a flat
     *      deterrent, not a valuation mechanism.
     * @param collection NFT collection address.
     * @param tokenId Token ID to fractionalize.
     * @param totalShares Number of ERC-20 shares to mint (> 1).
     * @param tokenName ERC-20 name for the fraction token.
     * @param tokenSymbol ERC-20 symbol for the fraction token.
     * @return vaultId The new vault identifier.
     */
    function fractionalize(
        address collection,
        uint256 tokenId,
        uint256 totalShares,
        string calldata tokenName,
        string calldata tokenSymbol
    ) external nonReentrant returns (uint256 vaultId) {
        if (totalShares < 2) revert InvalidShareCount();

        address caller = _msgSender();

        vaultId = nextVaultId;
        ++nextVaultId;

        // M-01: Collect creation fee if configured. The fee is
        // denominated in feeCurrency tokens and transferred to the
        // UnifiedFeeVault. If creationFeeBps is zero, no fee is charged.
        if (
            creationFeeBps > 0 &&
            feeCurrency != address(0) &&
            feeVault != address(0)
        ) {
            // Fee = totalShares * creationFeeBps / BPS_DENOMINATOR
            // Using totalShares as the fee base (share count as proxy
            // for collection value)
            uint256 feeAmount = (totalShares * creationFeeBps)
                / BPS_DENOMINATOR;
            if (feeAmount > 0) {
                IERC20(feeCurrency).safeTransferFrom(
                    caller, feeVault, feeAmount
                );
            }
        }

        // Deploy fraction token — mints all shares to caller
        FractionToken token = new FractionToken(
            tokenName,
            tokenSymbol,
            address(this),
            caller,
            totalShares
        );

        vaults[vaultId] = Vault({
            owner: caller,
            collection: collection,
            tokenId: tokenId,
            fractionToken: address(token),
            totalShares: totalShares,
            active: true,
            boughtOut: false,
            buyoutProposer: address(0),
            buyoutPrice: 0,
            buyoutCurrency: address(0),
            buyoutDeadline: 0
        });

        nftToVault[collection][tokenId] = vaultId;

        // Lock NFT in vault
        IERC721(collection).safeTransferFrom(
            caller,
            address(this),
            tokenId
        );

        emit Fractionalized(
            vaultId,
            caller,
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

        address caller = _msgSender();
        FractionToken token = FractionToken(v.fractionToken);
        uint256 balance = token.balanceOf(caller);
        if (balance < v.totalShares) revert InsufficientShares();

        v.active = false;

        // M-03: Use vaultBurn to skip ERC-20 allowance requirement
        token.vaultBurn(caller, v.totalShares);

        // Return NFT
        IERC721(v.collection).safeTransferFrom(
            address(this),
            caller,
            v.tokenId
        );

        emit Redeemed(vaultId, caller);
    }

    /**
     * @notice Propose a buyout for a fractionalized NFT.
     * @dev Proposer must deposit `totalPrice` in `currency`.
     *      Other holders can later claim pro-rata by burning tokens.
     *      Proposer must hold at least 25 % of total shares.
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
        _validateActiveVault(v);
        if (v.buyoutProposer != address(0)) {
            revert BuyoutAlreadyActive();
        }
        if (totalPrice == 0) revert ZeroBuyoutPrice();

        address caller = _msgSender();

        // H-04: Require proposer to hold >= 25 % of total shares
        _validateProposerShares(v, caller);

        v.buyoutProposer = caller;
        v.buyoutCurrency = currency;

        // H-02: Set buyout deadline
        v.buyoutDeadline = block.timestamp + BUYOUT_DEADLINE_DURATION; // solhint-disable-line not-rely-on-time

        // H-03: balance-before/after for fee-on-transfer tokens
        uint256 balBefore =
            IERC20(currency).balanceOf(address(this));
        IERC20(currency).safeTransferFrom(
            caller,
            address(this),
            totalPrice
        );
        uint256 received =
            IERC20(currency).balanceOf(address(this)) - balBefore;
        v.buyoutPrice = received;

        emit BuyoutProposed(vaultId, caller, received);
    }

    /**
     * @notice Execute a buyout: burn shares to claim pro-rata payment.
     * @dev Any share-holder (except the proposer) can call this to
     *      sell their shares at the buyout price. When all shares are
     *      burned, the NFT goes to the proposer.
     * @param vaultId Vault with active buyout.
     * @param sharesToSell Number of shares to sell.
     */
    function executeBuyout(
        uint256 vaultId,
        uint256 sharesToSell
    ) external nonReentrant {
        Vault storage v = vaults[vaultId];
        _validateActiveVault(v);
        if (v.buyoutProposer == address(0)) {
            revert NoBuyoutProposal();
        }
        if (sharesToSell == 0) revert InvalidShareCount();

        address caller = _msgSender();

        // H-04: Prevent proposer self-dealing
        if (caller == v.buyoutProposer) {
            revert ProposerCannotSellToSelf();
        }

        // H-02: Ensure buyout has not expired
        _validateBuyoutNotExpired(v);

        _processBuyoutSale(v, vaultId, sharesToSell, caller);
    }

    /**
     * @notice Cancel an expired buyout and refund remaining funds.
     * @dev Only the original proposer may cancel, and only after the
     *      buyout deadline has passed.
     * @param vaultId Vault with the expired buyout proposal.
     */
    function cancelBuyout(uint256 vaultId) external nonReentrant {
        Vault storage v = vaults[vaultId];
        _validateActiveVault(v);
        if (v.buyoutProposer == address(0)) {
            revert NoBuyoutProposal();
        }
        if (_msgSender() != v.buyoutProposer) revert NotProposer();

        // Only allow cancellation after the deadline
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp <= v.buyoutDeadline) {
            revert BuyoutStillActive();
        }

        // Cache values before clearing state (CEI pattern)
        address proposer = v.buyoutProposer;
        address currency = v.buyoutCurrency;

        // Audit fix M-01: Calculate remaining buyout funds from
        // vault-specific data rather than contract-wide balance.
        // This prevents draining funds belonging to other vaults
        // or creation fees held in the same currency.
        FractionToken token = FractionToken(v.fractionToken);
        uint256 sharesBurned =
            v.totalShares - token.totalSupply();
        uint256 alreadyPaid =
            (v.buyoutPrice * sharesBurned) / v.totalShares;
        uint256 refundAmount = v.buyoutPrice - alreadyPaid;

        // Reset buyout state
        v.buyoutProposer = address(0);
        v.buyoutPrice = 0;
        v.buyoutCurrency = address(0);
        v.buyoutDeadline = 0;

        // Refund remaining funds to proposer
        if (refundAmount > 0) {
            IERC20(currency).safeTransfer(proposer, refundAmount);
        }

        emit BuyoutCancelled(vaultId, proposer, refundAmount);
    }

    // ── Admin functions ──────────────────────────────────────────────

    /**
     * @notice Update the creation fee.
     * @param newFeeBps New fee in basis points.
     */
    function setCreationFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_CREATION_FEE_BPS) revert FeeTooHigh();
        creationFeeBps = newFeeBps;
    }

    /**
     * @notice Update the UnifiedFeeVault address -- receives 100% of
     *         creation fees for 70/20/10 distribution.
     * @param newFeeVault New UnifiedFeeVault address.
     */
    function setFeeVault(address newFeeVault) external onlyOwner {
        // NFTSuite M-04: Validate new fee vault is non-zero
        if (newFeeVault == address(0)) revert ZeroAddress();
        feeVault = newFeeVault;
    }

    // ── View functions ───────────────────────────────────────────────

    /**
     * @notice Get vault details.
     * @param vaultId The vault to query.
     * @return vaultOwner Original NFT owner.
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
            address vaultOwner,
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

    // ── Internal helpers ─────────────────────────────────────────────

    /**
     * @notice Process a buyout sale: burn shares, pay seller.
     * @dev Transfers NFT to proposer if all shares are burned.
     * @param v Vault storage reference.
     * @param vaultId Vault identifier for events.
     * @param sharesToSell Number of shares to sell.
     * @param caller The resolved caller address (via _msgSender).
     */
    function _processBuyoutSale(
        Vault storage v,
        uint256 vaultId,
        uint256 sharesToSell,
        address caller
    ) internal {
        FractionToken token = FractionToken(v.fractionToken);
        uint256 balance = token.balanceOf(caller);
        if (balance < sharesToSell) revert InsufficientShares();

        // Calculate pro-rata payment; protect against zero rounding
        uint256 payment =
            (v.buyoutPrice * sharesToSell) / v.totalShares;
        if (payment == 0) revert PaymentTooSmall();

        // M-03: Use vaultBurn to skip ERC-20 allowance requirement
        token.vaultBurn(caller, sharesToSell);

        // M-02: If this seller is the last (totalSupply == 0 after
        // burn), give them the entire remaining buyout balance to
        // prevent rounding dust from being stranded.
        if (token.totalSupply() == 0) {
            uint256 remainingBalance =
                IERC20(v.buyoutCurrency).balanceOf(address(this));
            if (remainingBalance > payment) {
                payment = remainingBalance;
            }
        }

        // Pay seller
        IERC20(v.buyoutCurrency).safeTransfer(
            caller,
            payment
        );

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

    /**
     * @notice Validate the vault exists and is active.
     * @dev Reverts with VaultNotFound or VaultNotActive.
     * @param v Vault storage reference to validate.
     */
    function _validateActiveVault(Vault storage v) internal view {
        if (v.owner == address(0)) revert VaultNotFound();
        if (!v.active) revert VaultNotActive();
    }

    /**
     * @notice Validate proposer holds >= 25 % of total shares.
     * @dev Reverts with InsufficientProposerShares.
     * @param v Vault storage reference.
     * @param caller The resolved caller address (via _msgSender).
     */
    function _validateProposerShares(
        Vault storage v,
        address caller
    ) internal view {
        FractionToken token = FractionToken(v.fractionToken);
        uint256 proposerBalance = token.balanceOf(caller);
        uint256 minRequired =
            (v.totalShares * MIN_PROPOSER_SHARE_BPS)
                / BPS_DENOMINATOR;
        if (proposerBalance < minRequired) {
            revert InsufficientProposerShares();
        }
    }

    /**
     * @notice Validate the buyout has not expired.
     * @dev Reverts with BuyoutExpired if past deadline.
     * @param v Vault storage reference.
     */
    function _validateBuyoutNotExpired(
        Vault storage v
    ) internal view {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > v.buyoutDeadline) {
            revert BuyoutExpired();
        }
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
