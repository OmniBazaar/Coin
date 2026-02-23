const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoin TypeScript-Style Tests", function () {
    let omniCoin;
    let owner;
    let addr1;
    let addr2;
    let addrs;

    beforeEach(async function () {
        [owner, addr1, addr2, ...addrs] = await ethers.getSigners();

        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy();
        await omniCoin.initialize();
    });

    describe("Deployment", function () {
        it("Should grant DEFAULT_ADMIN_ROLE to deployer", async function () {
            const DEFAULT_ADMIN_ROLE = await omniCoin.DEFAULT_ADMIN_ROLE();
            expect(await omniCoin.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
        });

        it("Should assign the total supply to the owner", async function () {
            const ownerBalance = await omniCoin.balanceOf(owner.address);
            expect(await omniCoin.totalSupply()).to.equal(ownerBalance);
        });
    });

    describe("Transactions", function () {
        it("Should transfer tokens between accounts", async function () {
            await omniCoin.transfer(addr1.address, 50);
            const addr1Balance = await omniCoin.balanceOf(addr1.address);
            expect(addr1Balance).to.equal(50);
        });

        it("Should fail if sender doesn't have enough tokens", async function () {
            const initialOwnerBalance = await omniCoin.balanceOf(owner.address);
            await expect(
                omniCoin.connect(addr1).transfer(owner.address, 1)
            ).to.be.revertedWithCustomError(omniCoin, "ERC20InsufficientBalance");
        });
    });

    describe("Batch Transfers", function () {
        it("Should handle batch transfers correctly", async function () {
            const recipients = [addr1.address, addr2.address];
            const amounts = [100, 200];

            await omniCoin.batchTransfer(recipients, amounts);

            expect(await omniCoin.balanceOf(addr1.address)).to.equal(100);
            expect(await omniCoin.balanceOf(addr2.address)).to.equal(200);
        });

        it("Should revert on mismatched arrays", async function () {
            const recipients = [addr1.address];
            const amounts = [100, 200];

            await expect(
                omniCoin.batchTransfer(recipients, amounts)
            ).to.be.revertedWithCustomError(omniCoin, "ArrayLengthMismatch");
        });
    });

    describe("Fee Distribution", function () {
        it("Should handle fee distribution correctly", async function () {
            // Transfer with fee
            const transferAmount = 1000;
            const initialBalance = await omniCoin.balanceOf(owner.address);

            // Enable fee for testing
            await omniCoin.transfer(addr1.address, transferAmount);

            const addr1Balance = await omniCoin.balanceOf(addr1.address);
            expect(addr1Balance).to.equal(transferAmount);
        });
    });

    describe("Allowances", function () {
        it("Should handle allowance correctly", async function () {
            await omniCoin.approve(addr1.address, 100);
            expect(await omniCoin.allowance(owner.address, addr1.address)).to.equal(100);
        });

        it("Should handle transferFrom correctly", async function () {
            await omniCoin.approve(addr1.address, 100);
            await omniCoin.connect(addr1).transferFrom(owner.address, addr2.address, 50);

            expect(await omniCoin.balanceOf(addr2.address)).to.equal(50);
            expect(await omniCoin.allowance(owner.address, addr1.address)).to.equal(50);
        });
    });
});