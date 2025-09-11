# Hardhat Setup Guide for OmniCoin

**Last Updated:** 2025-09-10
**Status:** Working Configuration ✅

## Overview

This guide documents the exact steps to start Hardhat for the OmniCoin module. Due to the npm workspace setup, there are specific requirements for running Hardhat successfully.

## Prerequisites

- Node.js >= 22.18.0
- npm >= 10.0.0
- All dependencies installed via `npm install` from the root OmniBazaar directory

## Key Understanding: Workspace Setup

The OmniBazaar project uses npm workspaces, which means:
- All node_modules are hoisted to `/home/rickc/OmniBazaar/node_modules`
- Individual modules (like Coin) do NOT have their own node_modules directories
- This is why running `npx hardhat node` from Coin directory works - it finds hardhat in the parent

## Step-by-Step Instructions

### 1. Navigate to the Coin Module

```bash
cd /home/rickc/OmniBazaar/Coin
```

### 2. Start Hardhat Node

```bash
npx hardhat node
```

**Expected Output:**
```
Started HTTP and WebSocket JSON-RPC server at http://127.0.0.1:8545/

Accounts
========

WARNING: These accounts, and their private keys, are publicly known.
Any funds sent to them on Mainnet or any other live network WILL BE LOST.

Account #0: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 (10000 ETH)
Private Key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
...
```

### 3. Verify Hardhat is Running

Check if port 8545 is listening:
```bash
netstat -tulpn 2>/dev/null | grep 8545
# or
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}'
```

## Common Issues and Solutions

### Issue: "Cannot find module '@nomicfoundation/hardhat-toolbox'"

**Cause:** Trying to run hardhat from a location without access to node_modules

**Solution:** 
1. Ensure you're in the Coin directory: `/home/rickc/OmniBazaar/Coin`
2. Run `npx hardhat node` (npx will find hardhat in parent node_modules)

### Issue: "You are not inside a Hardhat project"

**Cause:** Running hardhat from wrong directory

**Solution:** Navigate to `/home/rickc/OmniBazaar/Coin` first

### Issue: Port 8545 already in use

**Solution:** 
1. Kill existing process: `kill $(lsof -t -i:8545)`
2. Or use different port: `npx hardhat node --port 8546`

## Background Process Management

### Start in Background
```bash
npx hardhat node > hardhat.log 2>&1 &
```

### Check Background Process
```bash
ps aux | grep "hardhat node" | grep -v grep
```

### Stop Background Process
```bash
pkill -f "hardhat node"
```

## Network Configuration

The local Hardhat network uses these settings:
- **Chain ID:** 1337
- **RPC URL:** http://localhost:8545
- **Gas Price:** Auto
- **Gas Limit:** 30000000
- **Accounts:** 20 test accounts with 10000 ETH each

## Integration with Other Modules

When starting the full test environment:

1. **Start Hardhat** (this guide)
2. **Deploy Contracts**: `npx hardhat run scripts/deploy.js --network localhost`
3. **Start IPFS**: See `/home/rickc/OmniBazaar/Storage/IPFS_SETUP_GUIDE.md`
4. **Start Validator**: See `/home/rickc/OmniBazaar/Validator/VALIDATOR_SETUP_GUIDE.md`

## Quick Start Script

Create this helper script at `/home/rickc/OmniBazaar/start-hardhat.sh`:

```bash
#!/bin/bash
cd /home/rickc/OmniBazaar/Coin
echo "Starting Hardhat node..."
npx hardhat node
```

Make it executable: `chmod +x /home/rickc/OmniBazaar/start-hardhat.sh`

## Troubleshooting Commands

```bash
# Check if Hardhat is installed
npm list hardhat

# Check workspace configuration
npm list @nomicfoundation/hardhat-toolbox

# Verify hardhat config
npx hardhat compile

# Test connection to running node
npx hardhat console --network localhost
```

## Notes

- The Hardhat node resets on restart (no persistent state)
- Test accounts are deterministic (same addresses/keys each time)
- For persistent state, use `--fork` option with a mainnet/testnet URL
- Default block gas limit is 30M, adjustable in hardhat.config.js

---
**Remember:** Always start Hardhat from the `/home/rickc/OmniBazaar/Coin` directory!