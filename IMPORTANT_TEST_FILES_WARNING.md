# IMPORTANT WARNING: Test File Deletion Issue

## Date: 2025-08-04 19:45 UTC

## Issue Discovered
Git status shows 17 test files in `test/deprecated/` were marked for deletion. This was NOT intentional and these files should be preserved.

## Files Affected
- test/deprecated/DualTokenArchitecture.test.js
- test/deprecated/DualTokenIntegration.test.js
- test/deprecated/OmniCoinArbitration.test.js
- test/deprecated/OmniCoinBridge.test.js
- test/deprecated/OmniCoinCore.test.js
- test/deprecated/OmniCoinEscrowV2.business-logic.test.js
- test/deprecated/OmniCoinEscrowV2.test.js
- test/deprecated/integration/OmniCoin.integration.test.js
- test/deprecated/privacy/DEXSettlement.privacy.test.js
- test/deprecated/privacy/OmniCoinArbitration.privacy.test.js
- test/deprecated/privacy/OmniCoinBridge.privacy.test.js
- test/deprecated/privacy/OmniNFTMarketplace.privacy.test.js
- test/deprecated/privacy/README.md
- test/deprecated/privacy/runAllPrivacyTests.js
- test/deprecated/security/OmniCoin.security-fixed.test.js
- test/deprecated/security/OmniCoin.security.test.js

## Action Taken
- Files were NOT deleted
- Git checkout was used to ensure files remain in place
- The deprecated directory and all its contents are preserved

## Root Cause
Unknown - these deletions were not part of any documented work plan. Possibly related to the contract simplification work from 2025-08-02, but the deletion of tests was not mentioned in CURRENT_STATUS.md or commit messages.

## Recommendation
1. DO NOT delete these deprecated test files
2. They contain valuable test cases that may need to be adapted for the new simplified architecture
3. Always move files to deprecated/ rather than deleting them
4. Document any file moves/deletions in CURRENT_STATUS.md

## Other Changes in Coin Module
Minor updates to test files to match constructor changes:
- OmniBridge.test.js - Updated OmniCore constructor call
- OmniCore.test.js - Updated OmniCore constructor call  
- OmniGovernance.test.js - Updated OmniCore constructor call
- OmniMarketplace.test.js - Updated OmniCore constructor call

These changes appear to be legitimate test fixes to match contract updates.