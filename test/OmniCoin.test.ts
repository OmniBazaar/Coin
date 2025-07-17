import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
    OmniCoin,
    OmniCoinConfig,
    OmniCoinReputation,
    OmniCoinStaking,
    OmniCoinValidator,
    OmniCoinMultisig,
    OmniCoinPrivacy,
    OmniCoinGarbledCircuit,
    OmniCoinGovernor,
    OmniCoinEscrow,
    OmniCoinBridge
} from "../typechain-types";

describe("OmniCoin Integration", function () {
    let omniCoin: OmniCoin;
    let config: OmniCoinConfig;
    let reputation: OmniCoinReputation;
    let staking: OmniCoinStaking;
    let validator: OmniCoinValidator;
    let multisig: OmniCoinMultisig;
    let privacy: OmniCoinPrivacy;
    let garbledCircuit: OmniCoinGarbledCircuit;
    let governor: OmniCoinGovernor;
    let escrow: OmniCoinEscrow;
    let bridge: OmniCoinBridge;

    let owner: SignerWithAddress;
    let user1: SignerWithAddress;
    let user2: SignerWithAddress;
    let validator1: SignerWithAddress;

    const INITIAL_SUPPLY = ethers.utils.parseUnits("1000000000", 6); // 1 billion tokens

    beforeEach(async function () {
        [owner, user1, user2, validator1] = await ethers.getSigners();

        // Deploy config
        const OmniCoinConfig = await ethers.getContractFactory("OmniCoinConfig");
        config = await OmniCoinConfig.deploy();
        await config.deployed();

        // Deploy OmniCoin
        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy("OmniCoin", "OMNI", config.address);
        await omniCoin.deployed();

        // Deploy component contracts
        const OmniCoinReputation = await ethers.getContractFactory("OmniCoinReputation");
        reputation = await OmniCoinReputation.deploy();
        await reputation.deployed();

        const OmniCoinStaking = await ethers.getContractFactory("OmniCoinStaking");
        staking = await OmniCoinStaking.deploy();
        await staking.deployed();

        const OmniCoinValidator = await ethers.getContractFactory("OmniCoinValidator");
        validator = await OmniCoinValidator.deploy();
        await validator.deployed();

        const OmniCoinMultisig = await ethers.getContractFactory("OmniCoinMultisig");
        multisig = await OmniCoinMultisig.deploy();
        await multisig.deployed();

        const OmniCoinPrivacy = await ethers.getContractFactory("OmniCoinPrivacy");
        privacy = await OmniCoinPrivacy.deploy();
        await privacy.deployed();

        const OmniCoinGarbledCircuit = await ethers.getContractFactory("OmniCoinGarbledCircuit");
        garbledCircuit = await OmniCoinGarbledCircuit.deploy();
        await garbledCircuit.deployed();

        const OmniCoinGovernor = await ethers.getContractFactory("OmniCoinGovernor");
        governor = await OmniCoinGovernor.deploy();
        await governor.deployed();

        const OmniCoinEscrow = await ethers.getContractFactory("OmniCoinEscrow");
        escrow = await OmniCoinEscrow.deploy();
        await escrow.deployed();

        const OmniCoinBridge = await ethers.getContractFactory("OmniCoinBridge");
        bridge = await OmniCoinBridge.deploy();
        await bridge.deployed();

        // Initialize components
        await omniCoin.initializeComponents(
            reputation.address,
            staking.address,
            validator.address,
            multisig.address,
            privacy.address,
            garbledCircuit.address,
            governor.address,
            escrow.address,
            bridge.address
        );
    });

    describe("Component Integration", function () {
        it("Should initialize all components correctly", async function () {
            expect(await omniCoin.reputation()).to.equal(reputation.address);
            expect(await omniCoin.staking()).to.equal(staking.address);
            expect(await omniCoin.validator()).to.equal(validator.address);
            expect(await omniCoin.multisig()).to.equal(multisig.address);
            expect(await omniCoin.privacy()).to.equal(privacy.address);
            expect(await omniCoin.garbledCircuit()).to.equal(garbledCircuit.address);
            expect(await omniCoin.governor()).to.equal(governor.address);
            expect(await omniCoin.escrow()).to.equal(escrow.address);
            expect(await omniCoin.bridge()).to.equal(bridge.address);
        });
    });

    describe("Privacy Features", function () {
        it("Should enable privacy for a user", async function () {
            await omniCoin.connect(user1).enablePrivacy();
            expect(await privacy.isPrivacyEnabled(user1.address)).to.be.true;
        });

        it("Should disable privacy for a user", async function () {
            await omniCoin.connect(user1).enablePrivacy();
            await omniCoin.connect(user1).disablePrivacy();
            expect(await privacy.isPrivacyEnabled(user1.address)).to.be.false;
        });
    });

    describe("Validator System", function () {
        it("Should register a validator with sufficient reputation", async function () {
            // Set up reputation
            await reputation.setMinReputationForValidator(50);
            await reputation.updateReputation(validator1.address, 60, 0, 0, "Initial reputation");

            await omniCoin.connect(validator1).registerValidator();
            expect(await omniCoin.hasRole(await omniCoin.VALIDATOR_ROLE(), validator1.address)).to.be.true;
        });

        it("Should not register a validator with insufficient reputation", async function () {
            await reputation.setMinReputationForValidator(50);
            await reputation.updateReputation(validator1.address, 40, 0, 0, "Low reputation");

            await expect(omniCoin.connect(validator1).registerValidator())
                .to.be.revertedWith("Insufficient reputation");
        });
    });

    describe("Escrow System", function () {
        it("Should create and release an escrow", async function () {
            const amount = ethers.utils.parseUnits("1000", 6);
            const conditions = ethers.utils.id("test conditions");

            // Create escrow
            const tx = await omniCoin.connect(user1).createEscrow(user2.address, amount, conditions);
            const receipt = await tx.wait();
            const event = receipt.events?.find(e => e.event === "EscrowCreated");
            const escrowId = event?.args?.escrowId;

            // Release escrow
            await omniCoin.connect(user2).releaseEscrow(escrowId);
            expect(await escrow.isReleased(escrowId)).to.be.true;
        });

        it("Should create and refund an escrow", async function () {
            const amount = ethers.utils.parseUnits("1000", 6);
            const conditions = ethers.utils.id("test conditions");

            // Create escrow
            const tx = await omniCoin.connect(user1).createEscrow(user2.address, amount, conditions);
            const receipt = await tx.wait();
            const event = receipt.events?.find(e => e.event === "EscrowCreated");
            const escrowId = event?.args?.escrowId;

            // Refund escrow
            await omniCoin.connect(user1).refundEscrow(escrowId);
            expect(await escrow.isRefunded(escrowId)).to.be.true;
        });
    });

    describe("Bridge System", function () {
        it("Should perform a bridge transfer", async function () {
            const amount = ethers.utils.parseUnits("1000", 6);
            const chainName = "ethereum";

            // Add bridge
            await config.addBridge(chainName, bridge.address);

            // Enable privacy
            await omniCoin.connect(user1).enablePrivacy();

            // Grant bridge role
            await omniCoin.grantRole(await omniCoin.BRIDGE_ROLE(), bridge.address);

            // Perform bridge transfer
            await expect(omniCoin.connect(user1).bridgeTransfer(chainName, user2.address, amount))
                .to.emit(omniCoin, "Transfer")
                .withArgs(user1.address, user2.address, amount);
        });
    });

    describe("Security Features", function () {
        it("Should pause and unpause the contract", async function () {
            await omniCoin.pause();
            expect(await omniCoin.paused()).to.be.true;

            await omniCoin.unpause();
            expect(await omniCoin.paused()).to.be.false;
        });

        it("Should enforce multi-sig for large transfers", async function () {
            const amount = ethers.utils.parseUnits("1000000", 6); // 1 million tokens

            await expect(omniCoin.connect(user1).transfer(user2.address, amount))
                .to.be.revertedWith("Multi-sig required");
        });
    });
}); 