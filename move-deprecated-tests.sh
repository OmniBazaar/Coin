#!/bin/bash

# Move clearly deprecated test files
mv test/OmniCoinPaymentV2.business-logic.test.js test/deprecated/
mv test/OmniCoinPaymentV2.test.js test/deprecated/
mv test/OmniCoinRegistry.test.js test/deprecated/
mv test/OmniCoinReputationV2.test.js test/deprecated/
mv test/OmniCoinStakingV2.test.js test/deprecated/
mv test/privacy/OmniCoinCore.privacy.test.js test/deprecated/
mv test/privacy/OmniCoinEscrow.privacy.test.js test/deprecated/
mv test/privacy/OmniCoinPayment.privacy.test.js test/deprecated/
mv test/privacy/OmniCoinStaking.privacy.test.js test/deprecated/
mv test/reputation/OmniCoinIdentityVerification.test.js test/deprecated/
mv test/reputation/OmniCoinReferralSystem.test.js test/deprecated/
mv test/reputation/OmniCoinReputationCore.test.js test/deprecated/
mv test/reputation/OmniCoinTrustSystem.test.js test/deprecated/

# Move tests for contracts that no longer exist
mv test/OmniCoinAccount.test.js test/deprecated/
mv test/OmniCoinConfig.test.js test/deprecated/
mv test/OmniCoinGovernor.test.js test/deprecated/
mv test/OmniCoinMultisig.test.js test/deprecated/
mv test/OmniCoinValidator.test.js test/deprecated/
mv test/OmniWalletProvider.test.js test/deprecated/
mv test/OmniWalletRecovery.test.js test/deprecated/
mv test/ValidatorRegistry.test.js test/deprecated/
mv test/ValidatorSync.test.js test/deprecated/
mv test/OmniCoinPrivacyBridge.test.js test/deprecated/
mv test/OmniCoinGarbledCircuit.test.js test/deprecated/
mv test/OmniCoinPrivacy.test.js test/deprecated/
mv test/PrivacyFeeManager.credit.test.js test/deprecated/
mv test/FeeDistribution.test.js test/deprecated/
mv test/FeeDistribution.test.ts test/deprecated/
mv test/DEXSettlement.test.js test/deprecated/
mv test/OmniUnifiedMarketplace.test.js test/deprecated/
mv test/OmniNFTMarketplace.test.js test/deprecated/
mv test/BatchProcessor.test.js test/deprecated/
mv test/OmniBatchTransactions.test.js test/deprecated/
mv test/ListingNFT.test.js test/deprecated/
mv test/OmniERC1155.test.js test/deprecated/
mv test/OmniERC1155Bridge.test.js test/deprecated/
mv test/OmniERC1155.comprehensive.test.js test/deprecated/
mv test/OmniERC1155.minimal.test.js test/deprecated/
mv test/SecureSend.test.js test/deprecated/

echo "Moved deprecated tests to test/deprecated/"