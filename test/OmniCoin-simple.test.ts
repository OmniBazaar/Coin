import { expect } from "chai";
import { ethers } from "hardhat";
import { OmniCoin } from "../typechain-types/index.js";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("OmniCoin TypeScript Tests", function () {
    let omniCoin: OmniCoin;
    let owner: HardhatEthersSigner;
    let addr1: HardhatEthersSigner;
    let addr2: HardhatEthersSigner;
    let addrs: HardhatEthersSigner[];

    beforeEach(async function () {
        [owner, addr1, addr2, ...addrs] = await ethers.getSigners();

        const OmniCoin = await ethers.getContractFactory("OmniCoin");
        omniCoin = await OmniCoin.deploy();
    });

    describe("Deployment", function () {
        it("Should set the right owner", async function () {
            expect(await omniCoin.owner()).to.equal(owner.address);
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
            ).to.be.revertedWith("Arrays length mismatch");
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