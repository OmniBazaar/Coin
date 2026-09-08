// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";

/**
 * @title MockERC2981NFT
 * @notice Minimal ERC-721 + ERC-2981 mock so settlement tests can
 *         exercise the NFTMarketplaceEscrow royalty leg (N-ROY).
 * @dev Exposes unrestricted `mint` plus settable default and per-token
 *      royalties so a single deployment can cover the happy path,
 *      per-token overrides, and the over-cap clamp case.
 */
contract MockERC2981NFT is ERC721, ERC2981 {
    /// @notice Deploy the mock collection.
    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC721(name_, symbol_) {}

    /**
     * @notice Mint a token to any address (no access control).
     * @param to Recipient address.
     * @param tokenId Token ID to mint.
     */
    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    /**
     * @notice Set the collection-wide default royalty.
     * @param receiver Royalty recipient.
     * @param feeNumerator Royalty in basis points (denominator 10000).
     */
    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    /**
     * @notice Set a per-token royalty override.
     * @param tokenId Token to override.
     * @param receiver Royalty recipient.
     * @param feeNumerator Royalty in basis points (denominator 10000).
     */
    function setTokenRoyalty(
        uint256 tokenId,
        address receiver,
        uint96 feeNumerator
    ) external {
        _setTokenRoyalty(tokenId, receiver, feeNumerator);
    }

    /// @notice When true, {royaltyInfo} burns far more than the
    ///         marketplace's royalty gas ceiling before returning — used
    ///         to exercise the NFTMarketplaceEscrow I-1 gas cap.
    bool public gasGrief;

    /// @notice Toggle the gas-griefing behavior of {royaltyInfo}.
    /// @param on Whether `royaltyInfo` should burn excessive gas.
    function setGasGrief(bool on) external {
        gasGrief = on;
    }

    /// @inheritdoc ERC2981
    /// @dev When {gasGrief} is set, spins a data-dependent keccak loop
    ///      (not dead-code-eliminable) that consumes well beyond the
    ///      caller's gas stipend, forcing the gas-bounded STATICCALL to
    ///      run out of gas. Otherwise defers to the standard ERC2981.
    function royaltyInfo(
        uint256 tokenId,
        uint256 salePrice
    ) public view override returns (address, uint256) {
        if (gasGrief) {
            bytes32 h = bytes32(salePrice);
            for (uint256 i = 0; i < 5000; ++i) {
                h = keccak256(abi.encode(h, i));
            }
            // Anti-dead-code-elimination guard so the gas-burning loop
            // above is not optimized away; test-only mock, so a plain
            // require is clearer than a custom error here.
            // solhint-disable-next-line gas-custom-errors
            require(uint256(h) != type(uint256).max, "unreachable");
        }
        return super.royaltyInfo(tokenId, salePrice);
    }

    /// @inheritdoc ERC721
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
