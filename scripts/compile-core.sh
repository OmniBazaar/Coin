#!/bin/bash

echo "Compiling core dual-token contracts only..."

# Create temp directory with just core contracts
mkdir -p temp-core/contracts/base
cp contracts/OmniCoinRegistry.sol temp-core/contracts/
cp contracts/base/RegistryAware.sol temp-core/contracts/base/
cp contracts/OmniCoin.sol temp-core/contracts/
cp contracts/PrivateOmniCoin.sol temp-core/contracts/
cp contracts/PrivacyFeeManagerV2.sol temp-core/contracts/
cp contracts/OmniCoinPrivacyBridge.sol temp-core/contracts/
cp -r coti-contracts temp-core/

# Create minimal hardhat config
cat > temp-core/hardhat.config.js << EOF
require("@nomicfoundation/hardhat-toolbox");

module.exports = {
  solidity: {
    version: "0.8.19",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      },
      viaIR: true
    }
  }
};
EOF

# Copy package.json
cp package.json temp-core/
cp package-lock.json temp-core/

# Compile
cd temp-core
npx hardhat compile

# Copy artifacts back if successful
if [ -d "artifacts" ]; then
  echo "Copying artifacts back..."
  cp -r artifacts ../
fi

cd ..
rm -rf temp-core

echo "Done!"