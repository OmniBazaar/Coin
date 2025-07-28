const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniWalletRecovery", function () {
    let owner, wallet1, wallet2, guardian1, guardian2, guardian3, guardian4;
    let backupAddress, newOwner, user1, treasury;
    let recovery;
    let registry, omniCoin, identityVerification, reputationCore;
    
    // Constants
    const MIN_GUARDIANS = 2;
    const MAX_GUARDIANS = 10;
    const DEFAULT_RECOVERY_DELAY = 48 * 60 * 60; // 48 hours
    const MAX_RECOVERY_DELAY = 30 * 24 * 60 * 60; // 30 days
    const GUARDIAN_REPUTATION_THRESHOLD = 80;
    
    // Recovery methods
    const RecoveryMethod = {
        SOCIAL_RECOVERY: 0,
        MULTISIG_RECOVERY: 1,
        TIME_LOCKED_RECOVERY: 2,
        EMERGENCY_RECOVERY: 3
    };
    
    // Recovery status
    const RecoveryStatus = {
        PENDING: 0,
        APPROVED: 1,
        EXECUTED: 2,
        CANCELLED: 3,
        EXPIRED: 4
    };
    
    beforeEach(async function () {
        [owner, wallet1, wallet2, guardian1, guardian2, guardian3, guardian4,
         backupAddress, newOwner, user1, treasury] = await ethers.getSigners();
        
        // Deploy actual OmniCoinRegistry
        const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await OmniCoinRegistry.deploy(await owner.getAddress());
        await registry.waitForDeployment();
        
        // Deploy actual OmniCoin
        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy(await registry.getAddress());
        await omniCoin.waitForDeployment();
        
        // Deploy actual IdentityVerification (needed for guardian validation)
        const IdentityVerification = await ethers.getContractFactory("IdentityVerification");
        identityVerification = await IdentityVerification.deploy(
            await registry.getAddress()
        );
        await identityVerification.waitForDeployment();
        
        // Deploy actual ReputationCore (needed for guardian reputation)
        const ReputationCore = await ethers.getContractFactory("ReputationCore");
        reputationCore = await ReputationCore.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await reputationCore.waitForDeployment();
        
        // Set up registry
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN")),
            await omniCoin.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNIBAZAAR_TREASURY")),
            await treasury.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("IDENTITY_VERIFICATION")),
            await identityVerification.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("REPUTATION_CORE")),
            await reputationCore.getAddress()
        );
        
        // Deploy OmniWalletRecovery
        const OmniWalletRecovery = await ethers.getContractFactory("OmniWalletRecovery");
        recovery = await OmniWalletRecovery.deploy();
        await recovery.waitForDeployment();
        
        // Initialize recovery
        await recovery.initialize(await registry.getAddress());
    });
    
    describe("Deployment and Initialization", function () {
        it("Should set correct initial values", async function () {
            expect(await recovery.owner()).to.equal(await owner.getAddress());
            expect(await recovery.requestCounter()).to.equal(0);
            expect(await recovery.minGuardians()).to.equal(MIN_GUARDIANS);
            expect(await recovery.maxGuardians()).to.equal(MAX_GUARDIANS);
            expect(await recovery.defaultRecoveryDelay()).to.equal(DEFAULT_RECOVERY_DELAY);
            expect(await recovery.maxRecoveryDelay()).to.equal(MAX_RECOVERY_DELAY);
            expect(await recovery.guardianReputationThreshold()).to.equal(GUARDIAN_REPUTATION_THRESHOLD);
        });
        
        it("Should not allow reinitialization", async function () {
            await expect(
                recovery.initialize(await registry.getAddress())
            ).to.be.revertedWith("Initializable: contract is already initialized");
        });
    });
    
    describe("Recovery Configuration", function () {
        it("Should configure recovery with valid parameters", async function () {
            const guardians = [
                await guardian1.getAddress(),
                await guardian2.getAddress(),
                await guardian3.getAddress()
            ];
            const threshold = 2;
            const recoveryDelay = 72 * 60 * 60; // 72 hours
            
            await expect(recovery.connect(wallet1).configureRecovery(
                guardians,
                threshold,
                RecoveryMethod.SOCIAL_RECOVERY,
                recoveryDelay,
                await backupAddress.getAddress()
            )).to.emit(recovery, "RecoveryConfigured")
                .withArgs(
                    await wallet1.getAddress(),
                    guardians,
                    threshold,
                    RecoveryMethod.SOCIAL_RECOVERY
                );
            
            const config = await recovery.getWalletConfig(await wallet1.getAddress());
            expect(config.guardianList).to.deep.equal(guardians);
            expect(config.threshold).to.equal(threshold);
            expect(config.recoveryDelay).to.equal(recoveryDelay);
            expect(config.isActive).to.be.true;
            expect(config.preferredMethod).to.equal(RecoveryMethod.SOCIAL_RECOVERY);
        });
        
        it("Should reject configuration with too few guardians", async function () {
            const guardians = [await guardian1.getAddress()]; // Only 1 guardian
            
            await expect(recovery.connect(wallet1).configureRecovery(
                guardians,
                1,
                RecoveryMethod.SOCIAL_RECOVERY,
                DEFAULT_RECOVERY_DELAY,
                await backupAddress.getAddress()
            )).to.be.revertedWithCustomError(recovery, "InvalidGuardianCount");
        });
        
        it("Should reject configuration with too many guardians", async function () {
            const guardians = [];
            for (let i = 0; i < MAX_GUARDIANS + 1; i++) {
                guardians.push(ethers.Wallet.createRandom().address);
            }
            
            await expect(recovery.connect(wallet1).configureRecovery(
                guardians,
                1,
                RecoveryMethod.SOCIAL_RECOVERY,
                DEFAULT_RECOVERY_DELAY,
                await backupAddress.getAddress()
            )).to.be.revertedWithCustomError(recovery, "InvalidGuardianCount");
        });
        
        it("Should reject invalid threshold", async function () {
            const guardians = [
                await guardian1.getAddress(),
                await guardian2.getAddress()
            ];
            
            // Threshold = 0
            await expect(recovery.connect(wallet1).configureRecovery(
                guardians,
                0,
                RecoveryMethod.SOCIAL_RECOVERY,
                DEFAULT_RECOVERY_DELAY,
                await backupAddress.getAddress()
            )).to.be.revertedWithCustomError(recovery, "InvalidThreshold");
            
            // Threshold > guardian count
            await expect(recovery.connect(wallet1).configureRecovery(
                guardians,
                3,
                RecoveryMethod.SOCIAL_RECOVERY,
                DEFAULT_RECOVERY_DELAY,
                await backupAddress.getAddress()
            )).to.be.revertedWithCustomError(recovery, "InvalidThreshold");
        });
        
        it("Should reject invalid recovery delay", async function () {
            const guardians = [
                await guardian1.getAddress(),
                await guardian2.getAddress()
            ];
            
            // Too short (< 24 hours)
            await expect(recovery.connect(wallet1).configureRecovery(
                guardians,
                2,
                RecoveryMethod.SOCIAL_RECOVERY,
                20 * 60 * 60, // 20 hours
                await backupAddress.getAddress()
            )).to.be.revertedWithCustomError(recovery, "InvalidRecoveryDelay");
            
            // Too long (> max delay)
            await expect(recovery.connect(wallet1).configureRecovery(
                guardians,
                2,
                RecoveryMethod.SOCIAL_RECOVERY,
                MAX_RECOVERY_DELAY + 1,
                await backupAddress.getAddress()
            )).to.be.revertedWithCustomError(recovery, "InvalidRecoveryDelay");
        });
        
        it("Should reject self as guardian", async function () {
            const guardians = [
                await wallet1.getAddress(), // Self
                await guardian2.getAddress()
            ];
            
            await expect(recovery.connect(wallet1).configureRecovery(
                guardians,
                2,
                RecoveryMethod.SOCIAL_RECOVERY,
                DEFAULT_RECOVERY_DELAY,
                await backupAddress.getAddress()
            )).to.be.revertedWithCustomError(recovery, "CannotBeSelfGuardian");
        });
    });
    
    describe("Recovery Initiation", function () {
        beforeEach(async function () {
            // Configure recovery for wallet1
            const guardians = [
                await guardian1.getAddress(),
                await guardian2.getAddress(),
                await guardian3.getAddress()
            ];
            
            await recovery.connect(wallet1).configureRecovery(
                guardians,
                2, // threshold
                RecoveryMethod.SOCIAL_RECOVERY,
                DEFAULT_RECOVERY_DELAY,
                await backupAddress.getAddress()
            );
        });
        
        it("Should initiate social recovery by guardian", async function () {
            const evidence = ethers.toUtf8Bytes("Lost access to wallet");
            
            await expect(recovery.connect(guardian1).initiateRecovery(
                await wallet1.getAddress(),
                await newOwner.getAddress(),
                RecoveryMethod.SOCIAL_RECOVERY,
                evidence
            )).to.emit(recovery, "RecoveryRequested")
                .withArgs(
                    1, // requestId
                    await wallet1.getAddress(),
                    await newOwner.getAddress(),
                    RecoveryMethod.SOCIAL_RECOVERY
                );
            
            expect(await recovery.requestCounter()).to.equal(1);
            
            // Check that initiating guardian auto-approved
            await expect(recovery.connect(guardian1).initiateRecovery(
                await wallet1.getAddress(),
                await newOwner.getAddress(),
                RecoveryMethod.SOCIAL_RECOVERY,
                evidence
            )).to.emit(recovery, "RecoveryApproved");
        });
        
        it("Should initiate emergency recovery by backup address", async function () {
            const evidence = ethers.toUtf8Bytes("Emergency recovery needed");
            
            await expect(recovery.connect(backupAddress).initiateRecovery(
                await wallet1.getAddress(),
                await newOwner.getAddress(),
                RecoveryMethod.EMERGENCY_RECOVERY,
                evidence
            )).to.emit(recovery, "RecoveryRequested");
        });
        
        it("Should reject recovery initiation by non-guardian", async function () {
            const evidence = ethers.toUtf8Bytes("Unauthorized attempt");
            
            await expect(recovery.connect(user1).initiateRecovery(
                await wallet1.getAddress(),
                await newOwner.getAddress(),
                RecoveryMethod.SOCIAL_RECOVERY,
                evidence
            )).to.be.revertedWithCustomError(recovery, "NotAuthorizedToInitiate");
        });
        
        it("Should reject recovery for unconfigured wallet", async function () {
            const evidence = ethers.toUtf8Bytes("No config");
            
            await expect(recovery.connect(guardian1).initiateRecovery(
                await wallet2.getAddress(), // Not configured
                await newOwner.getAddress(),
                RecoveryMethod.SOCIAL_RECOVERY,
                evidence
            )).to.be.revertedWithCustomError(recovery, "RecoveryNotConfigured");
        });
        
        it("Should reject invalid new owner", async function () {
            const evidence = ethers.toUtf8Bytes("Invalid owner");
            
            await expect(recovery.connect(guardian1).initiateRecovery(
                await wallet1.getAddress(),
                ethers.ZeroAddress,
                RecoveryMethod.SOCIAL_RECOVERY,
                evidence
            )).to.be.revertedWithCustomError(recovery, "InvalidNewOwner");
        });
        
        it("Should reject same address as new owner", async function () {
            const evidence = ethers.toUtf8Bytes("Same owner");
            
            await expect(recovery.connect(guardian1).initiateRecovery(
                await wallet1.getAddress(),
                await wallet1.getAddress(), // Same as current
                RecoveryMethod.SOCIAL_RECOVERY,
                evidence
            )).to.be.revertedWithCustomError(recovery, "SameAsCurrentOwner");
        });
    });
    
    describe("Recovery Approval", function () {
        let requestId;
        
        beforeEach(async function () {
            // Configure recovery
            const guardians = [
                await guardian1.getAddress(),
                await guardian2.getAddress(),
                await guardian3.getAddress()
            ];
            
            await recovery.connect(wallet1).configureRecovery(
                guardians,
                2, // threshold
                RecoveryMethod.SOCIAL_RECOVERY,
                DEFAULT_RECOVERY_DELAY,
                await backupAddress.getAddress()
            );
            
            // Initiate recovery
            const evidence = ethers.toUtf8Bytes("Lost access");
            await recovery.connect(guardian1).initiateRecovery(
                await wallet1.getAddress(),
                await newOwner.getAddress(),
                RecoveryMethod.SOCIAL_RECOVERY,
                evidence
            );
            requestId = 1;
        });
        
        it("Should approve recovery by guardian", async function () {
            // Guardian1 already approved during initiation
            // Guardian2 approves
            await expect(recovery.connect(guardian2).approveRecovery(requestId))
                .to.emit(recovery, "RecoveryApproved")
                .withArgs(requestId, await guardian2.getAddress());
            
            // Check status should be APPROVED after threshold met
            const request = await recovery.recoveryRequests(requestId);
            expect(request.status).to.equal(RecoveryStatus.APPROVED);
        });
        
        it("Should reject double approval", async function () {
            // Guardian1 already approved, try again
            await expect(recovery.connect(guardian1).approveRecovery(requestId))
                .to.be.revertedWithCustomError(recovery, "AlreadyApproved");
        });
        
        it("Should reject approval by non-guardian", async function () {
            await expect(recovery.connect(user1).approveRecovery(requestId))
                .to.be.revertedWithCustomError(recovery, "NotAGuardian");
        });
        
        it("Should reject approval of non-pending request", async function () {
            // Approve to meet threshold
            await recovery.connect(guardian2).approveRecovery(requestId);
            
            // Cancel the request
            await recovery.connect(guardian1).cancelRecovery(requestId);
            
            // Try to approve cancelled request
            await expect(recovery.connect(guardian3).approveRecovery(requestId))
                .to.be.revertedWithCustomError(recovery, "RecoveryNotPending");
        });
    });
    
    describe("Recovery Execution", function () {
        let requestId;
        
        beforeEach(async function () {
            // Configure recovery
            const guardians = [
                await guardian1.getAddress(),
                await guardian2.getAddress(),
                await guardian3.getAddress()
            ];
            
            await recovery.connect(wallet1).configureRecovery(
                guardians,
                2, // threshold
                RecoveryMethod.SOCIAL_RECOVERY,
                DEFAULT_RECOVERY_DELAY,
                await backupAddress.getAddress()
            );
            
            // Initiate and approve recovery
            const evidence = ethers.toUtf8Bytes("Lost access");
            await recovery.connect(guardian1).initiateRecovery(
                await wallet1.getAddress(),
                await newOwner.getAddress(),
                RecoveryMethod.SOCIAL_RECOVERY,
                evidence
            );
            requestId = 1;
            
            // Approve by second guardian to meet threshold
            await recovery.connect(guardian2).approveRecovery(requestId);
        });
        
        it("Should execute recovery after delay", async function () {
            // Fast forward past recovery delay
            await ethers.provider.send("evm_increaseTime", [DEFAULT_RECOVERY_DELAY + 1]);
            await ethers.provider.send("evm_mine");
            
            await expect(recovery.connect(user1).executeRecovery(requestId))
                .to.emit(recovery, "RecoveryExecuted")
                .withArgs(
                    requestId,
                    await wallet1.getAddress(),
                    await newOwner.getAddress()
                );
            
            const request = await recovery.recoveryRequests(requestId);
            expect(request.status).to.equal(RecoveryStatus.EXECUTED);
        });
        
        it("Should reject execution before delay", async function () {
            // Try to execute immediately
            await expect(recovery.connect(user1).executeRecovery(requestId))
                .to.be.revertedWithCustomError(recovery, "RecoveryDelayNotElapsed");
        });
        
        it("Should reject execution of non-approved request", async function () {
            // Create new request without enough approvals
            const evidence = ethers.toUtf8Bytes("Another attempt");
            await recovery.connect(guardian1).initiateRecovery(
                await wallet1.getAddress(),
                await user1.getAddress(),
                RecoveryMethod.SOCIAL_RECOVERY,
                evidence
            );
            const newRequestId = 2;
            
            await expect(recovery.connect(user1).executeRecovery(newRequestId))
                .to.be.revertedWithCustomError(recovery, "RecoveryNotApproved");
        });
        
        it("Should increase guardian reputation on successful execution", async function () {
            // Fast forward and execute
            await ethers.provider.send("evm_increaseTime", [DEFAULT_RECOVERY_DELAY + 1]);
            await ethers.provider.send("evm_mine");
            
            await recovery.connect(user1).executeRecovery(requestId);
            
            // Check guardian reputations increased
            const guardian1Info = await recovery.guardians(await guardian1.getAddress());
            const guardian2Info = await recovery.guardians(await guardian2.getAddress());
            
            expect(guardian1Info.reputation).to.be.gt(GUARDIAN_REPUTATION_THRESHOLD);
            expect(guardian2Info.reputation).to.be.gt(GUARDIAN_REPUTATION_THRESHOLD);
        });
    });
    
    describe("Recovery Cancellation", function () {
        let requestId;
        
        beforeEach(async function () {
            // Configure and initiate recovery
            const guardians = [
                await guardian1.getAddress(),
                await guardian2.getAddress()
            ];
            
            await recovery.connect(wallet1).configureRecovery(
                guardians,
                2,
                RecoveryMethod.SOCIAL_RECOVERY,
                DEFAULT_RECOVERY_DELAY,
                await backupAddress.getAddress()
            );
            
            const evidence = ethers.toUtf8Bytes("Cancel test");
            await recovery.connect(guardian1).initiateRecovery(
                await wallet1.getAddress(),
                await newOwner.getAddress(),
                RecoveryMethod.SOCIAL_RECOVERY,
                evidence
            );
            requestId = 1;
        });
        
        it("Should cancel recovery by initiator", async function () {
            await expect(recovery.connect(guardian1).cancelRecovery(requestId))
                .to.emit(recovery, "RecoveryCancelled")
                .withArgs(requestId);
            
            const request = await recovery.recoveryRequests(requestId);
            expect(request.status).to.equal(RecoveryStatus.CANCELLED);
        });
        
        it("Should cancel recovery by wallet owner", async function () {
            await expect(recovery.connect(wallet1).cancelRecovery(requestId))
                .to.emit(recovery, "RecoveryCancelled");
        });
        
        it("Should cancel recovery by contract owner", async function () {
            await expect(recovery.connect(owner).cancelRecovery(requestId))
                .to.emit(recovery, "RecoveryCancelled");
        });
        
        it("Should reject cancellation by unauthorized party", async function () {
            await expect(recovery.connect(user1).cancelRecovery(requestId))
                .to.be.revertedWithCustomError(recovery, "NotAuthorizedToCancel");
        });
        
        it("Should reject cancellation of executed request", async function () {
            // Approve and execute
            await recovery.connect(guardian2).approveRecovery(requestId);
            await ethers.provider.send("evm_increaseTime", [DEFAULT_RECOVERY_DELAY + 1]);
            await ethers.provider.send("evm_mine");
            await recovery.connect(user1).executeRecovery(requestId);
            
            await expect(recovery.connect(guardian1).cancelRecovery(requestId))
                .to.be.revertedWithCustomError(recovery, "RecoveryNotCancellable");
        });
    });
    
    describe("Guardian Management", function () {
        beforeEach(async function () {
            // Configure recovery with initial guardians
            const guardians = [
                await guardian1.getAddress(),
                await guardian2.getAddress()
            ];
            
            await recovery.connect(wallet1).configureRecovery(
                guardians,
                2,
                RecoveryMethod.SOCIAL_RECOVERY,
                DEFAULT_RECOVERY_DELAY,
                await backupAddress.getAddress()
            );
        });
        
        it("Should add guardian", async function () {
            await expect(recovery.connect(wallet1).addGuardian(await guardian3.getAddress()))
                .to.emit(recovery, "GuardianAdded")
                .withArgs(await wallet1.getAddress(), await guardian3.getAddress());
            
            const config = await recovery.getWalletConfig(await wallet1.getAddress());
            expect(config.guardianList).to.include(await guardian3.getAddress());
            expect(config.guardianList.length).to.equal(3);
        });
        
        it("Should reject adding duplicate guardian", async function () {
            await expect(recovery.connect(wallet1).addGuardian(await guardian1.getAddress()))
                .to.be.revertedWithCustomError(recovery, "AlreadyAGuardian");
        });
        
        it("Should reject adding too many guardians", async function () {
            // Add guardians up to max
            for (let i = 2; i < MAX_GUARDIANS; i++) {
                const guardian = ethers.Wallet.createRandom();
                await recovery.connect(wallet1).addGuardian(guardian.address);
            }
            
            // Try to add one more
            await expect(recovery.connect(wallet1).addGuardian(ethers.Wallet.createRandom().address))
                .to.be.revertedWithCustomError(recovery, "TooManyGuardians");
        });
        
        it("Should remove guardian", async function () {
            await expect(recovery.connect(wallet1).removeGuardian(await guardian2.getAddress()))
                .to.emit(recovery, "GuardianRemoved")
                .withArgs(await wallet1.getAddress(), await guardian2.getAddress());
            
            const config = await recovery.getWalletConfig(await wallet1.getAddress());
            expect(config.guardianList).to.not.include(await guardian2.getAddress());
            expect(config.guardianList.length).to.equal(1);
        });
        
        it("Should reject removing below minimum guardians", async function () {
            // Try to remove when at minimum
            await expect(recovery.connect(wallet1).removeGuardian(await guardian1.getAddress()))
                .to.be.revertedWithCustomError(recovery, "TooFewGuardians");
        });
        
        it("Should adjust threshold when removing guardian", async function () {
            // Add third guardian and set threshold to 3
            await recovery.connect(wallet1).addGuardian(await guardian3.getAddress());
            
            // Remove a guardian - threshold should adjust
            await recovery.connect(wallet1).removeGuardian(await guardian3.getAddress());
            
            const config = await recovery.getWalletConfig(await wallet1.getAddress());
            expect(config.threshold).to.equal(2); // Adjusted from 3 to match guardian count
        });
    });
    
    describe("Backup Management", function () {
        it("Should create backup", async function () {
            const encryptedData = "encrypted_wallet_data_here";
            const authorizedRecoverers = [
                await guardian1.getAddress(),
                await guardian2.getAddress()
            ];
            
            const tx = await recovery.connect(wallet1).createBackup(
                encryptedData,
                authorizedRecoverers
            );
            const receipt = await tx.wait();
            
            // Get backup hash from event
            const event = receipt.logs.find(
                log => log.fragment && log.fragment.name === "BackupCreated"
            );
            expect(event).to.not.be.undefined;
            
            const backupHash = event.args[1];
            
            // Check backup data
            const backupData = await recovery.backups(backupHash);
            expect(backupData.encryptedData).to.equal(encryptedData);
            expect(backupData.isActive).to.be.true;
        });
        
        it("Should access backup by authorized recoverer", async function () {
            const encryptedData = "encrypted_wallet_data";
            const authorizedRecoverers = [await guardian1.getAddress()];
            
            const tx = await recovery.connect(wallet1).createBackup(
                encryptedData,
                authorizedRecoverers
            );
            const receipt = await tx.wait();
            const backupHash = receipt.logs.find(
                log => log.fragment && log.fragment.name === "BackupCreated"
            ).args[1];
            
            const retrievedData = await recovery.connect(guardian1).accessBackup(
                backupHash,
                await wallet1.getAddress()
            );
            expect(retrievedData).to.equal(encryptedData);
        });
        
        it("Should access backup by wallet owner", async function () {
            const encryptedData = "my_backup_data";
            const authorizedRecoverers = [];
            
            const tx = await recovery.connect(wallet1).createBackup(
                encryptedData,
                authorizedRecoverers
            );
            const receipt = await tx.wait();
            const backupHash = receipt.logs.find(
                log => log.fragment && log.fragment.name === "BackupCreated"
            ).args[1];
            
            const retrievedData = await recovery.connect(wallet1).accessBackup(
                backupHash,
                await wallet1.getAddress()
            );
            expect(retrievedData).to.equal(encryptedData);
        });
        
        it("Should reject backup access by unauthorized party", async function () {
            const encryptedData = "private_data";
            const authorizedRecoverers = [await guardian1.getAddress()];
            
            const tx = await recovery.connect(wallet1).createBackup(
                encryptedData,
                authorizedRecoverers
            );
            const receipt = await tx.wait();
            const backupHash = receipt.logs.find(
                log => log.fragment && log.fragment.name === "BackupCreated"
            ).args[1];
            
            await expect(recovery.connect(user1).accessBackup(
                backupHash,
                await wallet1.getAddress()
            )).to.be.revertedWithCustomError(recovery, "NotAuthorized");
        });
    });
    
    describe("View Functions", function () {
        it("Should get wallet requests", async function () {
            // Configure recovery
            const guardians = [
                await guardian1.getAddress(),
                await guardian2.getAddress()
            ];
            
            await recovery.connect(wallet1).configureRecovery(
                guardians,
                2,
                RecoveryMethod.SOCIAL_RECOVERY,
                DEFAULT_RECOVERY_DELAY,
                await backupAddress.getAddress()
            );
            
            // Create multiple recovery requests
            for (let i = 0; i < 3; i++) {
                await recovery.connect(guardian1).initiateRecovery(
                    await wallet1.getAddress(),
                    ethers.Wallet.createRandom().address,
                    RecoveryMethod.SOCIAL_RECOVERY,
                    ethers.toUtf8Bytes(`Request ${i}`)
                );
            }
            
            const requests = await recovery.getWalletRequests(await wallet1.getAddress());
            expect(requests.length).to.equal(3);
            expect(requests).to.deep.equal([1, 2, 3]);
        });
        
        it("Should get guarded wallets", async function () {
            // Configure recovery for multiple wallets with same guardian
            const wallets = [wallet1, wallet2];
            
            for (const wallet of wallets) {
                await recovery.connect(wallet).configureRecovery(
                    [await guardian1.getAddress(), await guardian2.getAddress()],
                    2,
                    RecoveryMethod.SOCIAL_RECOVERY,
                    DEFAULT_RECOVERY_DELAY,
                    await backupAddress.getAddress()
                );
            }
            
            const guardedWallets = await recovery.getGuardedWallets(await guardian1.getAddress());
            expect(guardedWallets.length).to.equal(2);
            expect(guardedWallets).to.include(await wallet1.getAddress());
            expect(guardedWallets).to.include(await wallet2.getAddress());
        });
    });
    
    describe("Admin Functions", function () {
        it("Should update recovery parameters", async function () {
            const newMinGuardians = 3;
            const newMaxGuardians = 15;
            const newDefaultDelay = 72 * 60 * 60; // 72 hours
            const newReputationThreshold = 90;
            
            await recovery.connect(owner).updateRecoveryParameters(
                newMinGuardians,
                newMaxGuardians,
                newDefaultDelay,
                newReputationThreshold
            );
            
            expect(await recovery.minGuardians()).to.equal(newMinGuardians);
            expect(await recovery.maxGuardians()).to.equal(newMaxGuardians);
            expect(await recovery.defaultRecoveryDelay()).to.equal(newDefaultDelay);
            expect(await recovery.guardianReputationThreshold()).to.equal(newReputationThreshold);
        });
        
        it("Should only allow owner to update parameters", async function () {
            await expect(recovery.connect(user1).updateRecoveryParameters(
                3, 15, 72 * 60 * 60, 90
            )).to.be.revertedWithCustomError(recovery, "OwnableUnauthorizedAccount");
        });
    });
    
    describe("Different Recovery Methods", function () {
        beforeEach(async function () {
            const guardians = [
                await guardian1.getAddress(),
                await guardian2.getAddress(),
                await guardian3.getAddress()
            ];
            
            await recovery.connect(wallet1).configureRecovery(
                guardians,
                2,
                RecoveryMethod.SOCIAL_RECOVERY,
                DEFAULT_RECOVERY_DELAY,
                await backupAddress.getAddress()
            );
        });
        
        it("Should handle multi-sig recovery (2/3 majority)", async function () {
            const evidence = ethers.toUtf8Bytes("Multi-sig recovery");
            
            await recovery.connect(guardian1).initiateRecovery(
                await wallet1.getAddress(),
                await newOwner.getAddress(),
                RecoveryMethod.MULTISIG_RECOVERY,
                evidence
            );
            
            // Multi-sig requires 2/3 of guardians (2 out of 3)
            await recovery.connect(guardian2).approveRecovery(1);
            
            const request = await recovery.recoveryRequests(1);
            expect(request.status).to.equal(RecoveryStatus.APPROVED);
        });
        
        it("Should handle emergency recovery", async function () {
            const evidence = ethers.toUtf8Bytes("Emergency!");
            
            await recovery.connect(backupAddress).initiateRecovery(
                await wallet1.getAddress(),
                await newOwner.getAddress(),
                RecoveryMethod.EMERGENCY_RECOVERY,
                evidence
            );
            
            // Emergency recovery only needs 1 approval (backup address)
            const request = await recovery.recoveryRequests(1);
            expect(request.requiredApprovals).to.equal(1);
        });
    });
});