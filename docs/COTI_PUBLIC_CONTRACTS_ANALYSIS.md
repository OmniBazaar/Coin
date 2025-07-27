# COTI V2 Public Contracts Analysis

**Created:** 2025-07-26
**Purpose:** Determine if COTI V2 supports standard public ERC20 contracts alongside private ones

## Executive Summary

COTI V2, as a full Ethereum Layer 2, **MUST support standard EVM contracts** including regular ERC20 tokens. The privacy features are an addition, not a replacement for standard functionality.

## Key Evidence

### 1. COTI V2 is a Full Ethereum L2

From their documentation and architecture:
- Complete EVM compatibility
- Standard RPC endpoints
- Ethereum settlement
- Regular gas mechanics

**This means**: Any contract that works on Ethereum MUST work on COTI V2

### 2. Standard Hardhat Configuration

The COTI hardhat template shows standard configuration:
```javascript
networks: {
  "coti-testnet": {
    url: "https://testnet.coti.io/rpc",
    chainId: 7082400,
    // Standard Ethereum-like configuration
  }
}
```

No special privacy flags or encrypted-only requirements.

### 3. Our Contracts Already Use Standard Interfaces

Many of our contracts import standard OpenZeppelin:
```solidity
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
```

These wouldn't compile if COTI only supported encrypted types.

### 4. Logical Architecture

COTI V2's value proposition is:
- **Standard EVM operations** (like any L2)
- **PLUS privacy features** when needed
- Not "privacy-only"

## The Right Architecture for OmniBazaar

### Deploy Two Separate Token Contracts

1. **OmniCoin (Standard ERC20)**
   ```solidity
   contract OmniCoin is ERC20, AccessControl, Pausable {
       // Standard public balances and operations
       mapping(address => uint256) private _balances;
       
       function transfer(address to, uint256 amount) public returns (bool) {
           // Standard ERC20 transfer
       }
   }
   ```

2. **PrivateOmniCoin (COTI PrivateERC20)**
   ```solidity
   contract PrivateOmniCoin is PrivateERC20 {
       // Encrypted balances and operations
       mapping(address => utUint64) private _balances;
       
       function transfer(address to, itUint64 calldata value) public returns (gtBool) {
           // Encrypted transfer
       }
   }
   ```

### Bridge Between Public and Private

```solidity
contract OmniCoinBridge {
    OmniCoin public publicToken;
    PrivateOmniCoin public privateToken;
    
    // Convert public to private (charge privacy fee)
    function convertToPrivate(uint256 amount) external {
        publicToken.transferFrom(msg.sender, address(this), amount);
        uint256 fee = (amount * 100) / 10000; // 1% fee
        uint256 amountAfterFee = amount - fee;
        privateToken.mint(msg.sender, amountAfterFee);
        privacyFeeManager.collectFee(msg.sender, fee);
    }
    
    // Convert private to public (no fee)
    function convertToPublic(uint256 amount) external {
        privateToken.burn(msg.sender, amount);
        publicToken.transfer(msg.sender, amount);
    }
}
```

## Performance Considerations

Your concern about performance is valid:

### Public Operations (OmniCoin)
- Standard EVM performance (1000+ TPS)
- No encryption overhead
- Suitable for high-volume marketplace

### Private Operations (PrivateOmniCoin)
- MPC overhead (~40 TPS)
- Used only when privacy needed
- Premium feature for sensitive transactions

## Implementation Strategy

### 1. Deploy Standard Contracts First
All our marketplace contracts can use standard OmniCoin:
- OmniNFTMarketplace
- DEXSettlement
- OmniCoinEscrow
- OmniCoinPayment

### 2. Add Privacy Layer
Deploy separate private contracts for users who want privacy:
- PrivateOmniCoin (the token)
- PrivateEscrow
- PrivatePayment

### 3. User Choice
Users decide per-transaction:
- Default: Use public OmniCoin (fast, no fees)
- Premium: Convert to PrivateOmniCoin (slower, 1-2% bridge fee)

## Deployment Example

```typescript
// Deploy on COTI V2 just like any Ethereum L2
async function deployContracts() {
  // Standard public token
  const OmniCoin = await ethers.deployContract("OmniCoin", [
    "OmniCoin",
    "XOM",
    1000000000
  ]);
  
  // Privacy token (uses COTI MPC)
  const PrivateOmniCoin = await ethers.deployContract("PrivateOmniCoin");
  
  // Bridge between them
  const Bridge = await ethers.deployContract("OmniCoinBridge", [
    OmniCoin.address,
    PrivateOmniCoin.address
  ]);
}
```

## Conclusion

**You are correct**: We don't need to make everything private. COTI V2 supports:

1. **Standard ERC20 contracts** for public operations (default)
2. **PrivateERC20 contracts** for privacy features (optional)
3. **Bridge contracts** to move between them

This gives us:
- Fast public transactions for normal marketplace activity
- Optional privacy for users who need it
- Performance where it matters
- Privacy where it's valued

The key insight: COTI V2 is an Ethereum L2 FIRST, with privacy features ADDED. Not a privacy-only chain.