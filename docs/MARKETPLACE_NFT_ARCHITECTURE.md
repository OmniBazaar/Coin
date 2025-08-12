# OmniBazaar NFT-Only Marketplace Architecture

**Date:** 2025-07-26 15:30 UTC  
**Status:** Architecture Decision Document

## Executive Summary

OmniBazaar marketplace will operate exclusively with NFTs on the OmniCoin (XOM) blockchain. All marketplace items - whether listings, art, gaming assets, or Real World Assets (RWAs) - will be represented as NFTs with metadata and media stored on IPFS.

## Key Design Decisions

### 1. Single Item Type: NFT

**All marketplace items are NFTs**:
- Product listings → Listing NFTs
- Digital art → Art NFTs  
- Gaming items → Gaming NFTs
- Real World Assets → RWA NFTs

**Benefits**:
- Unified code logic for all item types
- Simplified smart contract architecture
- Consistent user experience
- Standard NFT infrastructure/tooling

### 2. Storage Architecture

**On-Chain (OmniCoin Blockchain)**:
- NFT ownership records
- Basic metadata URI pointer
- Transaction history
- Pricing information
- Escrow states

**Off-Chain (IPFS)**:
- Product images/videos
- Detailed descriptions
- Specifications
- Additional media
- Metadata JSON files

### 3. NFT Metadata Standard

```json
{
  "name": "Product/Asset Name",
  "description": "Detailed description",
  "image": "ipfs://QmXxx...",
  "attributes": [
    {
      "trait_type": "Category",
      "value": "Electronics"
    },
    {
      "trait_type": "Condition", 
      "value": "New"
    },
    {
      "trait_type": "Location",
      "value": "USA"
    }
  ],
  "media": {
    "images": ["ipfs://QmXxx...", "ipfs://QmYyy..."],
    "videos": ["ipfs://QmZzz..."],
    "documents": ["ipfs://QmAaa..."]
  },
  "seller": {
    "address": "0x...",
    "reputation": 95,
    "verified": true
  }
}
```

### 4. Listing NFT Lifecycle

1. **Creation**:
   - Seller uploads media to IPFS
   - Creates metadata JSON on IPFS
   - Mints NFT pointing to metadata
   - NFT represents listing ownership

2. **Active Listing**:
   - NFT held by marketplace contract
   - Visible in marketplace UI
   - Can receive bids/offers

3. **Sale**:
   - Payment processed
   - NFT transferred to buyer
   - Listing NFT can be:
     - Burned (one-time listing)
     - Kept as proof of purchase
     - Re-listed by new owner

4. **Physical Item Delivery**:
   - For RWAs, NFT represents ownership claim
   - Physical delivery tracked off-chain
   - Dispute resolution via arbitration

### 5. Smart Contract Simplification

```solidity
contract OmniNFTMarketplace {
    // Single interface for all marketplace operations
    function createListing(
        address nftContract,
        uint256 tokenId,
        uint256 price,
        uint256 duration
    ) external;
    
    function buyItem(uint256 listingId) external;
    
    function placeBid(uint256 auctionId, uint256 amount) external;
    
    // Works for ALL NFT types - no special cases
}
```

### 6. Benefits of NFT-Only Approach

**Technical Benefits**:
- Single codebase for all items
- Standard ERC721/ERC1155 compatibility
- Existing NFT infrastructure works
- Simplified testing and maintenance

**User Benefits**:
- Ownership is clear and transferable
- Built-in provenance tracking
- Can trade listings themselves
- Standard wallet support

**Business Benefits**:
- Reduced development complexity
- Faster time to market
- Lower maintenance costs
- Easy integration with other NFT platforms

### 7. Implementation Phases

**Phase 1: Core NFT Marketplace**
- Basic listing/buying functionality
- IPFS integration for media
- Standard NFT support (ERC721)

**Phase 2: Enhanced Features**
- Batch operations
- ERC1155 support (multiple copies)
- Advanced search via metadata indexing
- Collection management

**Phase 3: RWA Integration**
- Physical asset verification
- Shipping integration
- Insurance options
- Legal framework compliance

### 8. IPFS Integration Strategy

**Pinning Service**:
- Use Pinata/Infura for reliability
- Validators can run IPFS nodes
- Redundant storage across network

**Content Addressing**:
- Immutable content via IPFS hashes
- Metadata updates create new versions
- Historical data preserved

**Performance**:
- CDN layer for fast media delivery
- Lazy loading for large files
- Thumbnail generation service

### 9. Migration from Existing Marketplaces

**Import Tools**:
- Scrapers for major platforms
- Bulk NFT minting service
- Automated metadata generation
- Preserve seller ratings/history

**Seller Incentives**:
- Free minting for first X listings
- Reduced fees for early adopters
- Marketing support
- Featured placement

### 10. Privacy Considerations

**Public Listings** (Default):
- Visible to all
- Standard NFT metadata
- No additional fees

**Private Listings** (Optional):
- Encrypted metadata on IPFS
- Private buyer/seller negotiation
- 10x privacy fees
- Uses COTI MPC for amounts

## Conclusion

The NFT-only marketplace approach dramatically simplifies our architecture while providing a superior user experience. By treating all marketplace items as NFTs with IPFS storage, we create a unified, scalable, and maintainable system that can handle any type of asset - from digital goods to real-world items.

This architecture aligns perfectly with our privacy-optional model, where users can choose between public (default) and private (premium) transactions for any NFT trade.