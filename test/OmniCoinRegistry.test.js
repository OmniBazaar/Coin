const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoinRegistry", function () {
    let registry;
    let owner, updater, user, emergencyAdmin;
    let testContract1, testContract2, testContract3;

    // Test identifiers
    const OMNICOIN_CORE = ethers.id("OMNICOIN_CORE");
    const REPUTATION_CORE = ethers.id("REPUTATION_CORE");
    const ESCROW = ethers.id("ESCROW");

    beforeEach(async function () {
        [owner, updater, user, emergencyAdmin] = await ethers.getSigners();

        // Deploy registry
        const Registry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await Registry.deploy(owner.address);

        // Deploy some test contracts
        const TestContract = await ethers.getContractFactory("OmniCoinConfig"); // Using existing contract for testing
        testContract1 = await TestContract.deploy(owner.address);
        testContract2 = await TestContract.deploy(owner.address);
        testContract3 = await TestContract.deploy(owner.address);

        // Grant updater role
        const UPDATER_ROLE = await registry.UPDATER_ROLE();
        await registry.grantRole(UPDATER_ROLE, updater.address);
    });

    describe("Deployment", function () {
        it("Should set correct admin", async function () {
            const ADMIN_ROLE = await registry.ADMIN_ROLE();
            expect(await registry.hasRole(ADMIN_ROLE, owner.address)).to.be.true;
        });

        it("Should set emergency contacts", async function () {
            expect(await registry.emergencyAdmin()).to.equal(owner.address);
            expect(await registry.emergencyFallback()).to.equal(owner.address);
        });
    });

    describe("Contract Registration", function () {
        it("Should register a new contract", async function () {
            await registry.registerContract(
                OMNICOIN_CORE,
                await testContract1.getAddress(),
                "Main token contract"
            );

            const info = await registry.getContractInfo(OMNICOIN_CORE);
            expect(info.contractAddress).to.equal(await testContract1.getAddress());
            expect(info.version).to.equal(1);
            expect(info.isActive).to.be.true;
            expect(info.description).to.equal("Main token contract");
        });

        it("Should prevent duplicate registration", async function () {
            await registry.registerContract(
                OMNICOIN_CORE,
                await testContract1.getAddress(),
                "Main token contract"
            );

            await expect(
                registry.registerContract(
                    OMNICOIN_CORE,
                    await testContract2.getAddress(),
                    "Duplicate"
                )
            ).to.be.revertedWith("Registry: Already registered");
        });

        it("Should batch register contracts", async function () {
            const identifiers = [OMNICOIN_CORE, REPUTATION_CORE, ESCROW];
            const addresses = [
                await testContract1.getAddress(),
                await testContract2.getAddress(),
                await testContract3.getAddress()
            ];
            const descriptions = ["Token", "Reputation", "Escrow"];

            await registry.batchRegister(identifiers, addresses, descriptions);

            expect(await registry.getContract(OMNICOIN_CORE)).to.equal(addresses[0]);
            expect(await registry.getContract(REPUTATION_CORE)).to.equal(addresses[1]);
            expect(await registry.getContract(ESCROW)).to.equal(addresses[2]);
        });

        it("Should emit registration event", async function () {
            await expect(
                registry.registerContract(
                    OMNICOIN_CORE,
                    await testContract1.getAddress(),
                    "Main token contract"
                )
            ).to.emit(registry, "ContractRegistered")
            .withArgs(
                OMNICOIN_CORE,
                await testContract1.getAddress(),
                1,
                "Main token contract"
            );
        });
    });

    describe("Contract Updates", function () {
        beforeEach(async function () {
            await registry.registerContract(
                OMNICOIN_CORE,
                await testContract1.getAddress(),
                "Main token contract"
            );
        });

        it("Should update contract address", async function () {
            await registry.connect(updater).updateContract(
                OMNICOIN_CORE,
                await testContract2.getAddress()
            );

            const info = await registry.getContractInfo(OMNICOIN_CORE);
            expect(info.contractAddress).to.equal(await testContract2.getAddress());
            expect(info.version).to.equal(2);
        });

        it("Should maintain version history", async function () {
            const addr1 = await testContract1.getAddress();
            const addr2 = await testContract2.getAddress();

            await registry.connect(updater).updateContract(OMNICOIN_CORE, addr2);

            expect(await registry.getContractAtVersion(OMNICOIN_CORE, 1)).to.equal(addr1);
            expect(await registry.getContractAtVersion(OMNICOIN_CORE, 2)).to.equal(addr2);
        });

        it("Should require updater role", async function () {
            await expect(
                registry.connect(user).updateContract(
                    OMNICOIN_CORE,
                    await testContract2.getAddress()
                )
            ).to.be.revertedWithCustomError(registry, "AccessControlUnauthorizedAccount");
        });

        it("Should emit update event", async function () {
            const oldAddr = await testContract1.getAddress();
            const newAddr = await testContract2.getAddress();

            await expect(
                registry.connect(updater).updateContract(OMNICOIN_CORE, newAddr)
            ).to.emit(registry, "ContractUpdated")
            .withArgs(OMNICOIN_CORE, oldAddr, newAddr, 2);
        });
    });

    describe("Contract Deactivation", function () {
        beforeEach(async function () {
            await registry.registerContract(
                OMNICOIN_CORE,
                await testContract1.getAddress(),
                "Main token contract"
            );
        });

        it("Should deactivate contract", async function () {
            await registry.deactivateContract(OMNICOIN_CORE);

            const info = await registry.getContractInfo(OMNICOIN_CORE);
            expect(info.isActive).to.be.false;
        });

        it("Should prevent getting deactivated contract", async function () {
            await registry.deactivateContract(OMNICOIN_CORE);

            await expect(
                registry.getContract(OMNICOIN_CORE)
            ).to.be.revertedWith("Registry: Contract inactive");
        });

        it("Should reactivate contract", async function () {
            await registry.deactivateContract(OMNICOIN_CORE);
            await registry.reactivateContract(OMNICOIN_CORE);

            const info = await registry.getContractInfo(OMNICOIN_CORE);
            expect(info.isActive).to.be.true;
        });
    });

    describe("Getter Functions", function () {
        beforeEach(async function () {
            const identifiers = [OMNICOIN_CORE, REPUTATION_CORE, ESCROW];
            const addresses = [
                await testContract1.getAddress(),
                await testContract2.getAddress(),
                await testContract3.getAddress()
            ];
            const descriptions = ["Token", "Reputation", "Escrow"];

            await registry.batchRegister(identifiers, addresses, descriptions);
        });

        it("Should get single contract", async function () {
            expect(await registry.getContract(OMNICOIN_CORE))
                .to.equal(await testContract1.getAddress());
        });

        it("Should get multiple contracts", async function () {
            const identifiers = [OMNICOIN_CORE, ESCROW];
            const addresses = await registry.getContracts(identifiers);

            expect(addresses[0]).to.equal(await testContract1.getAddress());
            expect(addresses[1]).to.equal(await testContract3.getAddress());
        });

        it("Should get all identifiers", async function () {
            const identifiers = await registry.getAllIdentifiers();
            expect(identifiers).to.include(OMNICOIN_CORE);
            expect(identifiers).to.include(REPUTATION_CORE);
            expect(identifiers).to.include(ESCROW);
            expect(identifiers.length).to.equal(3);
        });

        it("Should check if address is OmniCoin contract", async function () {
            expect(await registry.isOmniCoinContract(await testContract1.getAddress())).to.be.true;
            expect(await registry.isOmniCoinContract(user.address)).to.be.false;
        });
    });

    describe("Emergency Functions", function () {
        it("Should update emergency admin", async function () {
            await registry.updateEmergencyAdmin(emergencyAdmin.address);
            expect(await registry.emergencyAdmin()).to.equal(emergencyAdmin.address);
        });

        it("Should allow emergency pause", async function () {
            await registry.updateEmergencyAdmin(emergencyAdmin.address);
            await registry.connect(emergencyAdmin).emergencyPause();
            expect(await registry.paused()).to.be.true;
        });

        it("Should prevent operations when paused", async function () {
            await registry.emergencyPause();

            await expect(
                registry.registerContract(
                    ethers.id("NEW_CONTRACT"),
                    user.address,
                    "Test"
                )
            ).to.be.revertedWithCustomError(registry, "EnforcedPause");
        });
    });

    describe("Migration Support", function () {
        beforeEach(async function () {
            const identifiers = [OMNICOIN_CORE, REPUTATION_CORE, ESCROW];
            const addresses = [
                await testContract1.getAddress(),
                await testContract2.getAddress(),
                await testContract3.getAddress()
            ];
            const descriptions = ["Token", "Reputation", "Escrow"];

            await registry.batchRegister(identifiers, addresses, descriptions);
        });

        it("Should export registry data", async function () {
            const { identifiers, addresses, versions } = await registry.exportRegistry();

            expect(identifiers.length).to.equal(3);
            expect(addresses.length).to.equal(3);
            expect(versions.length).to.equal(3);

            expect(identifiers).to.include(OMNICOIN_CORE);
            expect(addresses).to.include(await testContract1.getAddress());
            expect(versions[0]).to.equal(1);
        });
    });

    describe("Gas Optimization", function () {
        it("Should be cheaper to update registry than multiple contracts", async function () {
            // Register initial contract
            await registry.registerContract(
                OMNICOIN_CORE,
                await testContract1.getAddress(),
                "Token"
            );

            // Measure gas for updating in registry
            const tx1 = await registry.connect(updater).updateContract(
                OMNICOIN_CORE,
                await testContract2.getAddress()
            );
            const receipt1 = await tx1.wait();
            const registryUpdateGas = receipt1.gasUsed;

            console.log(`Registry update gas: ${registryUpdateGas}`);
            
            // In reality, updating addresses in multiple contracts would cost
            // ~25,000 gas per contract × number of contracts using that address
            // Registry saves significant gas after 2-3 dependent contracts
            
            expect(registryUpdateGas).to.be.lt(100000); // Should be well under 100k
        });
    });
});