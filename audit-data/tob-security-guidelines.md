# Trail of Bits Security Guidelines (Adapted)

> Key security patterns from Trail of Bits' building-secure-contracts repository
> and not-so-smart-contracts collection. Organized by contract archetype for
> efficient audit reference.
>
> Sources:
> - [building-secure-contracts](https://github.com/crytic/building-secure-contracts)
> - [not-so-smart-contracts](https://github.com/crytic/not-so-smart-contracts)
> - [secure-contracts.com](https://secure-contracts.com/)
> - [crytic/properties](https://github.com/crytic/properties)

---

## ERC20 Token Contracts

### Key Invariants to Verify
- Sum of all balances MUST equal totalSupply at all times
- No individual balance should exceed totalSupply
- Transfer of 0 tokens should succeed (ERC20 spec)
- `approve` should overwrite, not accumulate
- `transferFrom` should decrease allowance (unless infinite)

### Security Checks
```solidity
// BAD: Missing zero-address check
function transfer(address to, uint256 amount) external returns (bool) {
    balances[msg.sender] -= amount;
    balances[to] += amount; // to could be address(0)
}

// GOOD: Validate recipients
function transfer(address to, uint256 amount) external returns (bool) {
    require(to != address(0), "zero address");
    require(to != address(this), "self-transfer");
    balances[msg.sender] -= amount;
    balances[to] += amount;
}
```

### Dangerous Token Patterns (Check When Integrating)
| Pattern | Risk | Detection |
|---------|------|-----------|
| Fee-on-transfer | Actual received < parameter amount | Check balance before/after |
| Rebasing | Balance changes without transfer | Use wrappers (wstETH) |
| Missing return bool | USDT, BNB don't return bool | Use SafeERC20 |
| Pausable | Token transfers can be blocked | Check for pause mechanism |
| Blocklist | Some addresses can be blocked | Check for blacklist mapping |
| Upgradeable | Token behavior can change | Check proxy pattern |
| Multiple entry points | Old + new contract both active | Verify canonical address |
| Flash-mintable | Temporary supply inflation | Check for flash mint |

---

## UUPS Upgradeable Contracts

### Critical Checks
1. **Implementation must call `_disableInitializers()` in constructor**
   ```solidity
   /// @custom:oz-upgrades-unsafe-allow constructor
   constructor() { _disableInitializers(); }
   ```
2. **`_authorizeUpgrade` must be restricted** (onlyOwner or governance)
3. **Storage layout must be append-only** — never insert or reorder variables
4. **Use `__gap` variables** for future-proofing base contracts
5. **Use `reinitializer(N)` for version-specific initialization** in upgrades

### Anti-Patterns (from Trail of Bits)
```solidity
// BAD: delegatecall with storage mismatch
contract Proxy {
    address public impl;         // slot 0
}
contract ImplV1 {
    uint256 public value;        // slot 0 — COLLIDES with impl!
}

// BAD: No initializer protection on implementation
contract Token is UUPSUpgradeable {
    function initialize() public initializer { ... }
    // Implementation contract is initializable by anyone!
}

// BAD: Removing or reordering inherited contracts
// V1: contract Token is ERC20, Ownable, UUPSUpgradeable
// V2: contract Token is Ownable, ERC20, UUPSUpgradeable  // BREAKS LAYOUT
```

### Trail of Bits Recommendation
> "We recommend against both [proxy upgrade] patterns... Use contract migration
> (deploying a new contract) rather than these complex mechanisms."

When upgrades ARE necessary:
- Use UUPS over Transparent Proxy (simpler, cheaper, fewer collision risks)
- Run `@openzeppelin/upgrades-core` storage layout checks in CI
- Never add state variables to base contracts without gap reduction
- Test upgrades on a fork before mainnet

---

## DEX / AMM Contracts

### Key Invariants
- Constant product invariant: `x * y = k` (must hold after every operation)
- No tokens should be extractable beyond what was deposited + earned fees
- Slippage bounds must be enforced (never `amountOutMin = 0`)
- Deadlines must be user-specified and checked (never `block.timestamp`)

### Security Checks
```solidity
// BAD: No slippage or deadline protection
function swap(uint amountIn, address[] path) external {
    router.swapExactTokensForTokens(amountIn, 0, path, msg.sender, block.timestamp);
}

// GOOD: User-controlled slippage and deadline
function swap(uint amountIn, uint amountOutMin, address[] path, uint deadline) external {
    require(block.timestamp <= deadline, "expired");
    router.swapExactTokensForTokens(amountIn, amountOutMin, path, msg.sender, deadline);
}
```

### Price Oracle Requirements
| Requirement | Why |
|------------|-----|
| Use TWAP >= 30 min window | Short windows are flash-loan manipulable |
| Use Chainlink as primary | Decentralized, manipulation-resistant |
| Check staleness (`updatedAt`) | Stale prices = wrong liquidations |
| Check `price > 0` | Zero/negative prices crash calculations |
| Multi-oracle fallback | Single source = single point of failure |
| Compare oracle vs spot | Large divergence = manipulation signal |

---

## Staking / Reward Contracts

### Key Invariants
- Sum of all stakes MUST equal contract's token balance (minus fees)
- Reward rate * time elapsed = total distributed rewards
- No user should be able to claim rewards they didn't earn
- Unstaking must return exactly the staked amount (minus penalties)

### Common Vulnerabilities
1. **Reward calculation overflow** — Check `rewardRate * duration` doesn't overflow
2. **First depositor attack** — Minimum stake requirement or dead shares
3. **recoverERC20 backdoor** — Must exclude staking + reward tokens
4. **Reward draining via re-stake** — Stake, claim, unstake, repeat in same block

### Security Checks
```solidity
// BAD: recoverERC20 can steal staking tokens
function recoverERC20(address token, uint amount) external onlyOwner {
    IERC20(token).transfer(owner, amount);
}

// GOOD: Exclude staking and reward tokens
function recoverERC20(address token, uint amount) external onlyOwner {
    require(token != stakingToken, "!staking");
    require(token != rewardsToken, "!rewards");
    IERC20(token).transfer(owner, amount);
}
```

```solidity
// BAD: No minimum stake allows share inflation
function stake(uint amount) external {
    uint shares = totalSupply == 0 ? amount : amount * totalSupply / totalStaked;
    _mint(msg.sender, shares);
}

// GOOD: Minimum stake + dead shares
function stake(uint amount) external {
    require(amount >= MIN_STAKE, "too low");
    if (totalSupply == 0) {
        _mint(address(0xdead), MINIMUM_SHARES); // dead shares prevent inflation
        _mint(msg.sender, amount - MINIMUM_SHARES);
    } else {
        uint shares = amount * totalSupply / totalStaked;
        require(shares > 0, "zero shares");
        _mint(msg.sender, shares);
    }
}
```

---

## Governance Contracts

### Key Invariants
- Voting power MUST use snapshots/checkpoints (not current balance)
- Proposals must have minimum thresholds to prevent spam
- Timelock between proposal passing and execution
- No single transaction should be able to pass a proposal (flash loan protection)

### Security Checks
```solidity
// BAD: Flash-loanable voting power
function getVotingPower(address user) public view returns (uint) {
    return token.balanceOf(user); // can be flash-loaned!
}

// GOOD: Checkpoint-based voting power
function getVotingPower(address user, uint blockNumber) public view returns (uint) {
    return token.getPastVotes(user, blockNumber);
}
```

### Governance Security Checklist
| Check | Why |
|-------|-----|
| Voting power from checkpoints | Prevents flash loan governance |
| Minimum proposal threshold | Prevents spam proposals |
| Voting delay (1+ blocks) | Forces commitment before vote |
| Timelock on execution | Allows users to exit before change |
| Quorum requirement | Prevents low-participation attacks |
| Guardian/veto role | Emergency brake on malicious proposals |

---

## Escrow / Multi-sig Contracts

### Key Invariants
- Funds locked until release conditions are met
- All parties must agree (or timeout triggers fallback)
- No single party can unilaterally withdraw

### Security Checks
- Verify timeouts don't allow premature or indefinite lockup
- Check that dispute resolution is reachable from every state
- Verify fee calculations don't exceed escrowed amount
- Test re-entrancy on release/refund functions

---

## General Security Patterns (All Contract Types)

### Access Control Best Practices
```solidity
// 1. Use role-based access control (not just onlyOwner)
bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

// 2. Separate concerns — different keys for different operations
// Fee setter ≠ Upgrader ≠ Pauser ≠ Minter

// 3. Use multi-sig for critical operations
// 4. Add timelocks for irreversible changes
// 5. Implement emergency pause with limited scope
```

### Checks-Effects-Interactions Pattern
```solidity
function withdraw(uint amount) external nonReentrant {
    // CHECKS
    require(balances[msg.sender] >= amount, "insufficient");

    // EFFECTS
    balances[msg.sender] -= amount;

    // INTERACTIONS
    (bool ok,) = msg.sender.call{value: amount}("");
    require(ok, "transfer failed");
}
```

### Emergency Response Design
From Trail of Bits' incident response recommendations:

1. **Implement granular pause** — Pause specific functions, not entire contract
2. **Document runbooks** — Pre-written procedures for common incidents
3. **Separate roles** — Fee setter ≠ upgrader ≠ pauser
4. **Use multisig** — Never use a single EOA for critical operations
5. **Monitor dependencies** — Track vulnerabilities in protocols you integrate with
6. **Fork-test upgrades** — Always test on mainnet fork before deploying

### Pre-Deployment Checklist
| Category | Check |
|----------|-------|
| **Compilation** | Compiles with fixed pragma, no warnings |
| **Static Analysis** | Slither + Aderyn clean (or false positives documented) |
| **Testing** | 100% line coverage on critical paths |
| **Fuzzing** | Echidna/Foundry fuzz tests for invariants |
| **Access Control** | All state-changing functions have appropriate modifiers |
| **Upgradability** | Storage layout verified, initializer protected |
| **External Calls** | All return values checked, reentrancy guarded |
| **Math** | No division-before-multiply, no unchecked user arithmetic |
| **Token Integration** | SafeERC20 used, fee-on-transfer considered |
| **Oracle** | Staleness checked, manipulation resistance verified |
| **Gas** | No unbounded loops, pull over push pattern used |
| **Events** | All state changes emit events for monitoring |

---

## Echidna Property Testing (Trail of Bits)

### Key Property Types for Audits
```solidity
// ERC20 Property: No balance exceeds total supply
function echidna_balance_lte_supply() public view returns (bool) {
    return token.balanceOf(address(this)) <= token.totalSupply();
}

// ERC4626 Property: Deposit preview matches actual
function echidna_deposit_preview() public returns (bool) {
    uint preview = vault.previewDeposit(amount);
    uint actual = vault.deposit(amount, address(this));
    return actual >= preview; // deposit should give >= preview shares
}

// Staking Property: Total staked matches sum of individual stakes
function echidna_total_staked_invariant() public view returns (bool) {
    return sumOfAllStakes() == staking.totalStaked();
}
```

### Pre-Built Property Sets (crytic/properties)
- **ERC20**: Standard compliance, balance/supply invariants, approval behavior
- **ERC4626**: Rounding direction, preview accuracy, share inflation resistance
- **ABDKMath64x64**: Mathematical properties (commutativity, associativity, ranges)

---

## Code Maturity Framework (Trail of Bits)

Trail of Bits evaluates smart contract maturity across 9 categories, each rated on a 5-level scale
(Missing / Weak / Moderate / Satisfactory / Strong):

| Category | Weak | Satisfactory |
|----------|------|-------------|
| **Arithmetic** | No overflow protection; unchecked casts | All arithmetic verified; explicit rounding |
| **Authentication** | Single EOA controls all | Multisig; least-privilege; 2-step ownership |
| **Complexity** | No function length limits | Functions < 25 lines; <3 levels nesting |
| **Decentralization** | Upgradeable by single entity | Users can exit; decentralization roadmap |
| **Documentation** | No NatSpec | All external functions documented |
| **Testing** | No tests | 100% coverage on critical paths; fuzz tests |
| **Tx Ordering (MEV)** | No slippage protection | Slippage checked; tamper-resistant oracles |
| **Low-Level** | Direct assembly use | Minimal assembly; documented purpose |
| **Auditing** | Never audited | External audit; all findings addressed |

## Known Non-Standard ERC20 Tokens

From Trail of Bits' [token integration checklist](https://secure-contracts.com/development-guidelines/token_integration.html):

| Token Behavior | Risk | Known Tokens |
|---------------|------|-------------|
| Missing revert on failure | Silent failure | BAT, HT, cUSDC, ZRX |
| Transfer hooks (reentrancy) | Callback re-entry | AMP, imBTC (ERC777) |
| Missing return data | SafeERC20 required | BNB, OMG, USDT |
| Permit fallback no-op | Phantom approval | WETH |
| Large approval revert | >2^96 fails | UNI, COMP |
| Pausable | Can trap dependent contracts | USDC, USDT |
| Blocklisted addresses | Transfers blocked | USDC, USDT |
| Upgradeable | Rules change post-deploy | USDC |
| Fee-on-transfer | Received < sent | STA, PAXG |
| Flash-mintable | Temporary supply spike | DAI |
| Rebasing | Balances change silently | stETH, AMPL, OHM |

## Not-So-Smart-Contracts Reference

Trail of Bits maintains example vulnerable contracts at [crytic/not-so-smart-contracts](https://github.com/crytic/not-so-smart-contracts):

| Category | Real-World Examples |
|----------|-------------------|
| Reentrancy | The DAO, SpankChain |
| Unprotected Function | Rubixi, Parity, BitGo v2, Nexus Mutual |
| Variable Shadowing | Various inherited contract bugs |
| Wrong Constructor | Pre-0.4.22 constructor name typos |
| Honeypots | Analysis of various honeypot tricks |
