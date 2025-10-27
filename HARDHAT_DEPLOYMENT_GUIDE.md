# Hardhat Deployment Guide for OmniCoin Contracts

**Last Updated:** 2025-10-27 15:04 UTC
**Purpose:** Document correct procedures for deploying and synchronizing OmniCore contracts

---

## 🎯 CRITICAL: Contract Address Management

### Single Source of Truth

**ALL modules MUST obtain contract addresses from synchronized config files:**
- `Validator/src/config/omnicoin-integration.ts`
- `WebApp/src/config/omnicoin-integration.ts`
- `Wallet/src/config/omnicoin-integration.ts`

**NEVER:**
- Hardcode addresses in scripts or services
- Read directly from `Coin/deployments/*.json`
- Copy addresses from documentation
- Use addresses from old deployment logs

**Synchronization is AUTOMATIC** - Just run the sync script after deploying.

---

## CRITICAL: Hardhat State Management

### Key Facts

1. **Hardhat runs in-memory by default** - All blockchain state is lost when Hardhat process stops
2. **Deployment scripts MUST use `npx hardhat run`** - Using `node scripts/deploy.js` connects to Hardhat but transactions may not mine properly
3. **Always start Hardhat FIRST** - Deploy immediately after starting to ensure state consistency
4. **Hardhat must remain running** - If Hardhat stops, ALL deployments are lost

### Common Pitfalls

❌ **DON'T:**
- Run deployment script with `node scripts/deploy-local.js` (transactions may not mine)
- Start Hardhat in different terminal contexts (state isolation issues)
- Kill Hardhat between validator restarts (loses all contract deployments)
- Use background processes with `&` without proper process management

✅ **DO:**
- Use `npx hardhat run scripts/deploy-local.js --network localhost`
- Start Hardhat in dedicated terminal/background job and leave it running
- Use `run_in_background` parameter in automated scripts
- Keep Hardhat process ID for proper cleanup

---

## Correct Deployment Procedure

### Step 1: Start Hardhat Node

**Option A: Interactive Terminal (Recommended for Development)**
```bash
cd /home/rickc/OmniBazaar/Coin
npx hardhat node
# Leave this terminal running, open new terminal for next steps
```

**Option B: Background Process (Automated)**
```bash
cd /home/rickc/OmniBazaar/Coin
nohup npx hardhat node > /tmp/hardhat.log 2>&1 &
HARDHAT_PID=$!
echo $HARDHAT_PID > /tmp/hardhat.pid
sleep 5  # Wait for Hardhat to start
```

**Verify Hardhat Started:**
```bash
lsof -i :8545 | grep LISTEN
curl -X POST http://localhost:8545 -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
```

Expected: Should show process listening on port 8545, curl returns chain ID 1337

### Step 2: Deploy Contracts

**CRITICAL: Use `npx hardhat run` command, NOT `node`**

```bash
cd /home/rickc/OmniBazaar/Coin
npx hardhat run scripts/deploy-local.js --network localhost
```

**Why this matters:**
- `npx hardhat run` ensures proper Hardhat network connection
- Transactions are mined immediately
- Deployment state persists in Hardhat's memory
- Contract bytecode is actually stored at addresses

**Output should show:**
```
🚀 Starting OmniCoin Local Deployment
...
OmniCore deployed to: 0xXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
✅ Deployment addresses saved to: .../deployments/localhost.json
```

**Note:** Address will be different each time Hardhat restarts. Don't hardcode!

### Step 3: Synchronize Contract Addresses

**CRITICAL: Run this after EVERY deployment**

```bash
cd /home/rickc/OmniBazaar
./scripts/sync-contract-addresses.sh localhost
```

This script:
1. Reads `Coin/deployments/localhost.json`
2. Updates `Validator/src/config/omnicoin-integration.ts`
3. Updates `WebApp/src/config/omnicoin-integration.ts`
4. Updates `Wallet/src/config/omnicoin-integration.ts`
5. Rebuilds all modules automatically

### Step 4: Verify Deployment

**Check contract exists:**
```bash
cd /home/rickc/OmniBazaar/Coin
node scripts/query-validators.js
```

Expected output:
```
==== OmniCore Validator Registry Query ====
Total registered nodes: 0
Active gateway validators: 0
```

**If you see "could not decode result data" error:**
- ❌ Contract was NOT deployed properly
- ❌ Hardhat may have restarted
- ❌ Deployment script used wrong method

**Check block number:**
```bash
curl -s -X POST http://localhost:8545 -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | jq
```

Should show blocks > 0 (deployments create blocks)

### Step 5: Start Validators

**CRITICAL: No need to set contract addresses manually!**

Validators automatically load addresses from `Validator/src/config/omnicoin-integration.ts`

```bash
cd /home/rickc/OmniBazaar/Validator

# Start validators (addresses loaded from config automatically)
npm run dev:validators 3

# Or with synthetic transactions for testing
ENABLE_SYNTHETIC_TXS=true SYNTHETIC_TPS=5 npm run dev:validators 3
```

**How it works:**
- dev-server-blockchain.ts imports `getContractAddresses('hardhat')`
- Addresses loaded from omnicoin-integration.ts (already synchronized in Step 3)
- No environment variables needed!

---

## Stopping and Restarting

### Graceful Shutdown

```bash
# Stop validators first
cd /home/rickc/OmniBazaar/Validator
./shutdown.sh --clean-registry

# Stop Hardhat
if [ -f /tmp/hardhat.pid ]; then
  kill $(cat /tmp/hardhat.pid)
  rm /tmp/hardhat.pid
fi

# Or use pkill (safer than killall)
pkill -f "hardhat node"
```

### Full Clean Restart

```bash
# 1. Stop everything
cd /home/rickc/OmniBazaar/Validator
./shutdown.sh --clean-registry
pkill -f "hardhat node"
sleep 2

# 2. Verify ports clear
lsof -i :8545 || echo "Port 8545 free"
lsof -i :3001 || echo "Port 3001 free"

# 3. Start Hardhat
cd /home/rickc/OmniBazaar/Coin
npx hardhat node > /tmp/hardhat.log 2>&1 &
echo $! > /tmp/hardhat.pid
sleep 5

# 4. Deploy contracts
npx hardhat run scripts/deploy-local.js --network localhost

# 5. Synchronize contract addresses (CRITICAL!)
cd /home/rickc/OmniBazaar
./scripts/sync-contract-addresses.sh localhost

# 6. Verify deployment
cd /home/rickc/OmniBazaar/Coin
node scripts/query-validators.js

# 7. Start validators (addresses loaded from config automatically)
cd /home/rickc/OmniBazaar/Validator
npm run dev:validators 3
```

---

## Troubleshooting

### Problem: "could not decode result data (value="0x")"

**Symptom:** Query script or validators get empty responses from contract calls

**Cause:** Contract doesn't exist at that address

**Solutions:**
1. Check if Hardhat restarted (loses all state)
2. Verify contract address matches deployment
3. Check block number > 0 (deployment creates blocks)
4. Verify using correct RPC URL (http://localhost:8545)
5. **Redeploy using `npx hardhat run`** (NOT `node`)

### Problem: "WARNING: Calling an account which is not a contract"

**Symptom:** Hardhat logs show warning when calling contract address

**Cause:** Contract bytecode not stored at address (deployment didn't actually deploy)

**Solutions:**
1. Kill Hardhat completely
2. Start fresh Hardhat instance
3. Deploy using `npx hardhat run scripts/deploy-local.js --network localhost`
4. Verify immediately with query script

### Problem: Port 8545 Already in Use

**Symptom:** Cannot start Hardhat, port conflict

**Solutions:**
```bash
# Find process using port
lsof -i :8545

# Kill specific process
kill -9 <PID>

# Or kill all Hardhat processes
pkill -f "hardhat node"

# Verify port free
lsof -i :8545 || echo "Port clear"
```

### Problem: Deployment Says Success But Contract Not Working

**Symptom:** Deployment script completes, but contract queries fail

**Cause:** Deployment script connected to different Hardhat instance or transactions didn't mine

**Solution:**
1. Check Hardhat logs (`/tmp/hardhat.log` or terminal output)
2. Look for transaction receipts in Hardhat output
3. Verify block number increased
4. **Always use `npx hardhat run --network localhost`**

---

## Testing Deployment

### Quick Verification Script

```bash
#!/bin/bash
# Save as: test-deployment.sh

COIN_DIR="/home/rickc/OmniBazaar/Coin"

echo "=== Checking Hardhat ==="
if lsof -i :8545 > /dev/null; then
  echo "✅ Hardhat running on port 8545"
else
  echo "❌ Hardhat NOT running"
  exit 1
fi

echo ""
echo "=== Checking Deployment File ==="
if [ -f "$COIN_DIR/deployments/localhost.json" ]; then
  OMNICORE=$(jq -r '.contracts.OmniCore' $COIN_DIR/deployments/localhost.json)
  echo "✅ Deployment file exists"
  echo "   OmniCore: $OMNICORE"
else
  echo "❌ No deployment file found"
  exit 1
fi

echo ""
echo "=== Testing Contract ==="
cd $COIN_DIR
if node scripts/query-validators.js 2>&1 | grep -q "Total registered nodes"; then
  echo "✅ Contract working correctly"
else
  echo "❌ Contract not responding"
  exit 1
fi

echo ""
echo "✅ ALL CHECKS PASSED - Ready to start validators"
```

### Usage:
```bash
chmod +x test-deployment.sh
./test-deployment.sh
```

---

## Best Practices

1. **Keep Hardhat Running** - Start once, use for entire dev session
2. **Deploy Immediately** - After starting Hardhat, deploy contracts right away
3. **Verify Before Validators** - Always test contract with query script
4. **Use Correct Command** - `npx hardhat run --network localhost` for all deployments
5. **Check Logs** - Monitor `/tmp/hardhat.log` for deployment transactions
6. **Save PID** - Store Hardhat process ID for clean shutdown
7. **Clean Restarts** - When restarting, stop everything and redeploy

---

## Quick Reference

| Task | Command |
|------|---------|
| Start Hardhat | `npx hardhat node` (terminal) or `npx hardhat node > /tmp/hardhat.log 2>&1 &` (background) |
| Deploy Contracts | `npx hardhat run scripts/deploy-local.js --network localhost` |
| Verify Deployment | `node scripts/query-validators.js` |
| Check Hardhat | `lsof -i :8545` |
| Stop Hardhat | `pkill -f "hardhat node"` |
| Get Contract Address | `jq -r '.contracts.OmniCore' deployments/localhost.json` |

---

**Remember:** Hardhat is in-memory. If it stops, everything is lost. Always redeploy after restarting Hardhat.
