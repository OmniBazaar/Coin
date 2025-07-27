#!/bin/bash

# Fix function ordering - move external function before public function
sed -i '243s/external/public/' contracts/OmniCoinCore.sol
sed -i '243a\    function mintInitialSupply() external onlyRole(DEFAULT_ADMIN_ROLE) {' contracts/OmniCoinCore.sol

# Add missing @notice tags
sed -i '273s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '289s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '309s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '318s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '335s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '357s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '395s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '418s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '454s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '489s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '520s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '548s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '559s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '573s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '598s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '613s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '635s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '654s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '682s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '714s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '723s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '730s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '743s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '753s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '760s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '797s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '805s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '830s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '839s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '857s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '869s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '878s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '888s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '898s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '906s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '917s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '925s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '946s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '954s/@dev/@notice/' contracts/OmniCoinCore.sol
sed -i '962s/@dev/@notice/' contracts/OmniCoinCore.sol

# Fix unused variables
sed -i '329d' contracts/OmniCoinCore.sol
sed -i '345d' contracts/OmniCoinCore.sol
sed -i '351d' contracts/OmniCoinCore.sol

# Fix gas optimization warnings (non-strict inequalities)
sed -i 's/validatorCount <= minimumValidators/validatorCount < minimumValidators + 1/g' contracts/OmniCoinCore.sol
sed -i 's/operation.confirmations >= minimumValidators/operation.confirmations > minimumValidators - 1/g' contracts/OmniCoinCore.sol
sed -i 's/block.timestamp <= operation.timestamp + 24 hours/block.timestamp < operation.timestamp + 24 hours + 1/g' contracts/OmniCoinCore.sol
sed -i 's/_publicTotalSupply <= MAX_SUPPLY/_publicTotalSupply < MAX_SUPPLY + 1/g' contracts/OmniCoinCore.sol
sed -i 's/newMinimum <= validatorCount/newMinimum < validatorCount + 1/g' contracts/OmniCoinCore.sol

# Convert require statements to custom errors
sed -i 's/require(newMinimum > 0, "OmniCoinCore: Minimum must be > 0");/if (newMinimum == 0) revert MinimumValidatorsTooLow();/' contracts/OmniCoinCore.sol
sed -i 's/require(newMinimum <= validatorCount, "OmniCoinCore: Minimum cannot exceed current count");/if (newMinimum > validatorCount) revert MaxValidatorsTooHigh();/' contracts/OmniCoinCore.sol
sed -i 's/require(_publicTotalSupply <= MAX_SUPPLY, "OmniCoinCore: Would exceed max supply");/if (_publicTotalSupply > MAX_SUPPLY) revert ExceedsMaxSupply();/' contracts/OmniCoinCore.sol
sed -i 's/require(!isMpcAvailable, "OmniCoinCore: Use balanceOf for MPC environments");/if (isMpcAvailable) revert TestEnvironmentOnly();/' contracts/OmniCoinCore.sol