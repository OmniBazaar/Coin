const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoinPrivacy", function () {
    let owner, user1, user2, treasury, feeRecipient;
    let registry, omniCoin, privateOmniCoin, garbledCircuitContract;
    let privacy;
    
    // Constants
    const MIN_DEPOSIT = ethers.parseUnits("10", 6);
    const MAX_WITHDRAWAL = ethers.parseUnits("10000", 6);
    const PRIVACY_FEE = ethers.parseUnits("0.1", 6); // 0.1 token fee
    
    // Helper function to generate commitment
    function generateCommitment(address, nonce) {
        return ethers.keccak256(ethers.solidityPacked(["address", "uint256"], [address, nonce]));
    }
    
    // Helper function to generate nullifier
    function generateNullifier(commitment, secret) {
        return ethers.keccak256(ethers.solidityPacked(["bytes32", "uint256"], [commitment, secret]));
    }
    
    beforeEach(async function () {
        [owner, user1, user2, treasury, feeRecipient] = await ethers.getSigners();
        
        // Deploy actual OmniCoinRegistry
        const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await OmniCoinRegistry.deploy(await owner.getAddress());
        await registry.waitForDeployment();
        
        // Deploy actual OmniCoin
        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy(await registry.getAddress());
        await omniCoin.waitForDeployment();
        
        // For PrivateOmniCoin, use StandardERC20Test
        const StandardERC20Test = await ethers.getContractFactory("contracts/test/StandardERC20Test.sol:StandardERC20Test");
        privateOmniCoin = await StandardERC20Test.deploy();
        await privateOmniCoin.waitForDeployment();
        
        // Deploy actual OmniCoinGarbledCircuit
        const OmniCoinGarbledCircuit = await ethers.getContractFactory("OmniCoinGarbledCircuit");
        garbledCircuitContract = await OmniCoinGarbledCircuit.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await garbledCircuitContract.waitForDeployment();
        
        // Set up registry
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNICOIN")),
            await omniCoin.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("PRIVATE_OMNICOIN")),
            await privateOmniCoin.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("OMNIBAZAAR_TREASURY")),
            await treasury.getAddress()
        );
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("GARBLED_CIRCUIT")),
            await garbledCircuitContract.getAddress()
        );
        
        // Deploy OmniCoinPrivacy
        const OmniCoinPrivacy = await ethers.getContractFactory("OmniCoinPrivacy");
        privacy = await OmniCoinPrivacy.deploy(
            await registry.getAddress(),
            await privateOmniCoin.getAddress() // uses private token for privacy operations
        );
        await privacy.waitForDeployment();
        
        // Fund users with private tokens
        const fundAmount = ethers.parseUnits("10000", 6);
        await privateOmniCoin.mint(await user1.getAddress(), fundAmount);
        await privateOmniCoin.mint(await user2.getAddress(), fundAmount);
        
        // Approve privacy contract
        await privateOmniCoin.connect(user1).approve(await privacy.getAddress(), ethers.MaxUint256);
        await privateOmniCoin.connect(user2).approve(await privacy.getAddress(), ethers.MaxUint256);
    });
    
    describe("Deployment and Configuration", function () {
        it("Should set correct initial values", async function () {
            expect(await privacy.owner()).to.equal(await owner.getAddress());
            expect(await privacy.minDeposit()).to.equal(MIN_DEPOSIT);
            expect(await privacy.maxWithdrawal()).to.equal(MAX_WITHDRAWAL);
            expect(await privacy.privacyFee()).to.equal(PRIVACY_FEE);
        });
        
        it("Should update minimum deposit", async function () {
            const newMin = ethers.parseUnits("5", 6);
            
            await expect(privacy.connect(owner).setMinDeposit(newMin))
                .to.emit(privacy, "MinDepositUpdated")
                .withArgs(MIN_DEPOSIT, newMin);
            
            expect(await privacy.minDeposit()).to.equal(newMin);
        });
        
        it("Should update maximum withdrawal", async function () {
            const newMax = ethers.parseUnits("50000", 6);
            
            await expect(privacy.connect(owner).setMaxWithdrawal(newMax))
                .to.emit(privacy, "MaxWithdrawalUpdated")
                .withArgs(MAX_WITHDRAWAL, newMax);
            
            expect(await privacy.maxWithdrawal()).to.equal(newMax);
        });
        
        it("Should update privacy fee", async function () {
            const newFee = ethers.parseUnits("0.2", 6);
            
            await expect(privacy.connect(owner).setPrivacyFee(newFee))
                .to.emit(privacy, "PrivacyFeeUpdated")
                .withArgs(PRIVACY_FEE, newFee);
            
            expect(await privacy.privacyFee()).to.equal(newFee);
        });
        
        it("Should only allow owner to update parameters", async function () {
            await expect(
                privacy.connect(user1).setMinDeposit(100)
            ).to.be.revertedWithCustomError(privacy, "OwnableUnauthorizedAccount");
        });
    });
    
    describe("Account Creation", function () {
        it("Should create a privacy account", async function () {
            const commitment = generateCommitment(await user1.getAddress(), 1);
            
            await expect(privacy.connect(user1).createAccount(commitment))
                .to.emit(privacy, "AccountCreated")
                .withArgs(commitment, await user1.getAddress());
            
            const account = await privacy.accounts(commitment);
            expect(account.commitment).to.equal(commitment);
            expect(account.balance).to.equal(0);
            expect(account.nonce).to.equal(0);
            expect(account.isActive).to.be.true;
        });
        
        it("Should fail with zero commitment", async function () {
            await expect(
                privacy.connect(user1).createAccount(ethers.ZeroHash)
            ).to.be.revertedWithCustomError(privacy, "ZeroCommitment");
        });
        
        it("Should fail if account already exists", async function () {
            const commitment = generateCommitment(await user1.getAddress(), 1);
            
            await privacy.connect(user1).createAccount(commitment);
            
            await expect(
                privacy.connect(user1).createAccount(commitment)
            ).to.be.revertedWithCustomError(privacy, "AccountExists");
        });
    });
    
    describe("Deposits", function () {
        const commitment = generateCommitment(ethers.Wallet.createRandom().address, 1);
        const depositAmount = ethers.parseUnits("100", 6);
        
        beforeEach(async function () {
            await privacy.connect(user1).createAccount(commitment);
        });
        
        it("Should deposit tokens to privacy account", async function () {
            const balanceBefore = await privateOmniCoin.balanceOf(await user1.getAddress());
            const privacyBalanceBefore = await privateOmniCoin.balanceOf(await privacy.getAddress());
            
            await expect(privacy.connect(user1).deposit(commitment, depositAmount))
                .to.emit(privacy, "Deposit")
                .withArgs(commitment, depositAmount);
            
            expect(await privateOmniCoin.balanceOf(await user1.getAddress()))
                .to.equal(balanceBefore - depositAmount);
            expect(await privateOmniCoin.balanceOf(await privacy.getAddress()))
                .to.equal(privacyBalanceBefore + depositAmount);
            
            const account = await privacy.accounts(commitment);
            expect(account.balance).to.equal(depositAmount);
        });
        
        it("Should fail if amount is zero", async function () {
            await expect(
                privacy.connect(user1).deposit(commitment, 0)
            ).to.be.revertedWithCustomError(privacy, "ZeroAmount");
        });
        
        it("Should fail if below minimum deposit", async function () {
            await expect(
                privacy.connect(user1).deposit(commitment, MIN_DEPOSIT - 1n)
            ).to.be.revertedWithCustomError(privacy, "BelowMinDeposit");
        });
        
        it("Should fail if account doesn't exist", async function () {
            const invalidCommitment = generateCommitment(await user2.getAddress(), 2);
            
            await expect(
                privacy.connect(user1).deposit(invalidCommitment, depositAmount)
            ).to.be.revertedWithCustomError(privacy, "InactiveAccount");
        });
        
        it("Should handle multiple deposits", async function () {
            await privacy.connect(user1).deposit(commitment, depositAmount);
            await privacy.connect(user1).deposit(commitment, depositAmount);
            
            const account = await privacy.accounts(commitment);
            expect(account.balance).to.equal(depositAmount * 2n);
        });
    });
    
    describe("Withdrawals", function () {
        const commitment = generateCommitment(ethers.Wallet.createRandom().address, 1);
        const depositAmount = ethers.parseUnits("1000", 6);
        const withdrawAmount = ethers.parseUnits("500", 6);
        const nullifier = generateNullifier(commitment, 12345);
        // Generate proof using actual structure expected by verifyWithdrawal
        const proof = ethers.AbiCoder.defaultAbiCoder().encode(
            ["bytes32", "uint256", "uint256"],
            [
                ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
                    ["bytes32", "bytes32", "uint256", "uint256"],
                    [commitment, nullifier, amount, Date.now()]
                )),
                0, // circuitId
                Date.now() // timestamp
            ]
        );
        
        beforeEach(async function () {
            await privacy.connect(user1).createAccount(commitment);
            await privacy.connect(user1).deposit(commitment, depositAmount);
        });
        
        it("Should withdraw tokens from privacy account", async function () {
            const balanceBefore = await privateOmniCoin.balanceOf(await user1.getAddress());
            const accountBalanceBefore = (await privacy.accounts(commitment)).balance;
            
            await expect(
                privacy.connect(user1).withdraw(commitment, nullifier, withdrawAmount, proof)
            ).to.emit(privacy, "Withdrawal")
                .withArgs(commitment, nullifier, withdrawAmount);
            
            // Check token transfer (amount - fee)
            const expectedAmount = withdrawAmount - PRIVACY_FEE;
            expect(await privateOmniCoin.balanceOf(await user1.getAddress()))
                .to.equal(balanceBefore + expectedAmount);
            
            // Check account balance updated
            const account = await privacy.accounts(commitment);
            expect(account.balance).to.equal(accountBalanceBefore - withdrawAmount);
            
            // Check nullifier marked as spent
            expect(await privacy.spentNullifiers(nullifier)).to.be.true;
        });
        
        it("Should fail with zero amount", async function () {
            await expect(
                privacy.connect(user1).withdraw(commitment, nullifier, 0, proof)
            ).to.be.revertedWithCustomError(privacy, "ZeroAmount");
        });
        
        it("Should fail if exceeds max withdrawal", async function () {
            await expect(
                privacy.connect(user1).withdraw(commitment, nullifier, MAX_WITHDRAWAL + 1n, proof)
            ).to.be.revertedWithCustomError(privacy, "ExceedsMaxWithdrawal");
        });
        
        it("Should fail if nullifier already spent", async function () {
            await privacy.connect(user1).withdraw(commitment, nullifier, withdrawAmount, proof);
            
            await expect(
                privacy.connect(user1).withdraw(commitment, nullifier, withdrawAmount, proof)
            ).to.be.revertedWithCustomError(privacy, "NullifierAlreadySpent");
        });
        
        it("Should fail if insufficient balance", async function () {
            await expect(
                privacy.connect(user1).withdraw(commitment, nullifier, depositAmount + 1n, proof)
            ).to.be.revertedWithCustomError(privacy, "InsufficientBalance");
        });
    });
    
    describe("Private Transfers", function () {
        const fromCommitment = generateCommitment(ethers.Wallet.createRandom().address, 1);
        const toCommitment = generateCommitment(ethers.Wallet.createRandom().address, 2);
        const depositAmount = ethers.parseUnits("1000", 6);
        const transferAmount = ethers.parseUnits("300", 6);
        const nullifier = generateNullifier(fromCommitment, 54321);
        // Generate proof using actual structure expected by verifyTransfer
        const proof = ethers.AbiCoder.defaultAbiCoder().encode(
            ["bytes32", "uint256", "uint256"],
            [
                ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
                    ["bytes32", "bytes32", "uint256", "bytes32"],
                    [commitment1, commitment2, amount, nullifier]
                )),
                0, // circuitId
                Date.now() // timestamp
            ]
        );
        
        beforeEach(async function () {
            // Create accounts
            await privacy.connect(user1).createAccount(fromCommitment);
            await privacy.connect(user2).createAccount(toCommitment);
            
            // Fund sender account
            await privacy.connect(user1).deposit(fromCommitment, depositAmount);
        });
        
        it("Should transfer between privacy accounts", async function () {
            const senderBalanceBefore = (await privacy.accounts(fromCommitment)).balance;
            const recipientBalanceBefore = (await privacy.accounts(toCommitment)).balance;
            
            await expect(
                privacy.transfer(
                    fromCommitment,
                    toCommitment,
                    nullifier,
                    transferAmount,
                    proof
                )
            ).to.emit(privacy, "Transfer")
                .withArgs(fromCommitment, toCommitment, nullifier, transferAmount);
            
            // Check balances updated
            const senderAccount = await privacy.accounts(fromCommitment);
            const recipientAccount = await privacy.accounts(toCommitment);
            
            expect(senderAccount.balance).to.equal(senderBalanceBefore - transferAmount);
            expect(recipientAccount.balance).to.equal(recipientBalanceBefore + transferAmount);
            
            // Check nullifier marked as spent
            expect(await privacy.spentNullifiers(nullifier)).to.be.true;
        });
        
        it("Should fail with zero amount", async function () {
            await expect(
                privacy.transfer(fromCommitment, toCommitment, nullifier, 0, proof)
            ).to.be.revertedWithCustomError(privacy, "ZeroAmount");
        });
        
        it("Should fail if sender has insufficient balance", async function () {
            await expect(
                privacy.transfer(
                    fromCommitment,
                    toCommitment,
                    nullifier,
                    depositAmount + 1n,
                    proof
                )
            ).to.be.revertedWithCustomError(privacy, "InsufficientBalance");
        });
        
        it("Should fail if nullifier already used", async function () {
            await privacy.transfer(
                fromCommitment,
                toCommitment,
                nullifier,
                transferAmount,
                proof
            );
            
            await expect(
                privacy.transfer(
                    fromCommitment,
                    toCommitment,
                    nullifier,
                    transferAmount,
                    proof
                )
            ).to.be.revertedWithCustomError(privacy, "NullifierAlreadySpent");
        });
    });
    
    describe("Account Management", function () {
        const commitment = generateCommitment(ethers.Wallet.createRandom().address, 1);
        
        beforeEach(async function () {
            await privacy.connect(user1).createAccount(commitment);
        });
        
        it("Should deactivate account", async function () {
            await expect(privacy.connect(owner).deactivateAccount(commitment))
                .to.emit(privacy, "AccountDeactivated")
                .withArgs(commitment);
            
            const account = await privacy.accounts(commitment);
            expect(account.isActive).to.be.false;
        });
        
        it("Should reactivate account", async function () {
            await privacy.connect(owner).deactivateAccount(commitment);
            
            await expect(privacy.connect(owner).reactivateAccount(commitment))
                .to.emit(privacy, "AccountReactivated")
                .withArgs(commitment);
            
            const account = await privacy.accounts(commitment);
            expect(account.isActive).to.be.true;
        });
        
        it("Should only allow owner to manage account status", async function () {
            await expect(
                privacy.connect(user1).deactivateAccount(commitment)
            ).to.be.revertedWithCustomError(privacy, "OwnableUnauthorizedAccount");
        });
    });
    
    describe("Proof Verification", function () {
        it("Should verify withdrawal proof", async function () {
            // This is a placeholder - in production would use actual ZK proofs
            const result = await privacy.verifyWithdrawal(
                ethers.ZeroHash,
                ethers.ZeroHash,
                0,
                "0x"
            );
            expect(result).to.be.true; // Simplified verification in current implementation
        });
        
        it("Should verify transfer proof", async function () {
            // This is a placeholder - in production would use actual ZK proofs
            const result = await privacy.verifyTransfer(
                ethers.ZeroHash,
                ethers.ZeroHash,
                ethers.ZeroHash,
                0,
                "0x"
            );
            expect(result).to.be.true; // Simplified verification in current implementation
        });
    });
    
    describe("Pause Functionality", function () {
        const commitment = generateCommitment(ethers.Wallet.createRandom().address, 1);
        
        beforeEach(async function () {
            await privacy.connect(user1).createAccount(commitment);
        });
        
        it("Should pause and unpause contract", async function () {
            await privacy.connect(owner).pause();
            expect(await privacy.paused()).to.be.true;
            
            await expect(
                privacy.connect(user1).deposit(commitment, ethers.parseUnits("100", 6))
            ).to.be.revertedWithCustomError(privacy, "EnforcedPause");
            
            await privacy.connect(owner).unpause();
            expect(await privacy.paused()).to.be.false;
        });
    });
});