const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

describe("MintController", function () {
  async function deployFixture() {
    const [deployer, minter, recipient, other] = await ethers.getSigners();

    // Deploy OmniCoin
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    const token = await OmniCoin.deploy();
    await token.waitForDeployment();
    await token.initialize();

    // Deploy MintController
    const MintController = await ethers.getContractFactory("MintController");
    const controller = await MintController.deploy(await token.getAddress());
    await controller.waitForDeployment();

    // Grant MINTER_ROLE on OmniCoin to the MintController and deployer
    const MINTER_ROLE = await token.MINTER_ROLE();
    await token.grantRole(MINTER_ROLE, await controller.getAddress());
    await token.grantRole(MINTER_ROLE, deployer.address);

    // Grant MINTER_ROLE on MintController to the minter
    const CONTROLLER_MINTER_ROLE = await controller.MINTER_ROLE();
    await controller.grantRole(CONTROLLER_MINTER_ROLE, minter.address);

    return { token, controller, deployer, minter, recipient, other, MINTER_ROLE, CONTROLLER_MINTER_ROLE };
  }

  describe("Deployment", function () {
    it("should set the token address correctly", async function () {
      const { token, controller } = await loadFixture(deployFixture);
      expect(await controller.TOKEN()).to.equal(await token.getAddress());
    });

    it("should revert deployment with zero address", async function () {
      const MintController = await ethers.getContractFactory("MintController");
      await expect(
        MintController.deploy(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(MintController, "InvalidAddress");
    });

    it("should grant deployer DEFAULT_ADMIN_ROLE and MINTER_ROLE", async function () {
      const { controller, deployer, CONTROLLER_MINTER_ROLE } = await loadFixture(deployFixture);
      const DEFAULT_ADMIN_ROLE = await controller.DEFAULT_ADMIN_ROLE();
      expect(await controller.hasRole(DEFAULT_ADMIN_ROLE, deployer.address)).to.be.true;
      expect(await controller.hasRole(CONTROLLER_MINTER_ROLE, deployer.address)).to.be.true;
    });
  });

  describe("View Functions", function () {
    it("maxSupplyCap should return 16.6 billion", async function () {
      const { controller } = await loadFixture(deployFixture);
      const cap = await controller.maxSupplyCap();
      expect(cap).to.equal(ethers.parseEther("16600000000"));
    });

    it("remainingMintable should account for initial supply", async function () {
      const { controller, token } = await loadFixture(deployFixture);
      const remaining = await controller.remainingMintable();
      const initialSupply = await token.totalSupply();
      const maxSupply = await controller.maxSupplyCap();
      expect(remaining).to.equal(maxSupply - initialSupply);
    });

    it("currentSupply should match token totalSupply", async function () {
      const { controller, token } = await loadFixture(deployFixture);
      expect(await controller.currentSupply()).to.equal(await token.totalSupply());
    });
  });

  describe("Minting", function () {
    it("should mint tokens successfully under the cap", async function () {
      const { controller, token, minter, recipient } = await loadFixture(deployFixture);
      const mintAmount = ethers.parseEther("1000");
      const supplyBefore = await token.totalSupply();

      await expect(controller.connect(minter).mint(recipient.address, mintAmount))
        .to.emit(controller, "ControlledMint")
        .withArgs(recipient.address, mintAmount, supplyBefore + mintAmount);

      expect(await token.balanceOf(recipient.address)).to.equal(mintAmount);
      expect(await token.totalSupply()).to.equal(supplyBefore + mintAmount);
    });

    it("should revert when minting zero amount", async function () {
      const { controller, minter, recipient } = await loadFixture(deployFixture);
      await expect(
        controller.connect(minter).mint(recipient.address, 0)
      ).to.be.revertedWithCustomError(controller, "ZeroAmount");
    });

    it("should revert when minting to zero address", async function () {
      const { controller, minter } = await loadFixture(deployFixture);
      await expect(
        controller.connect(minter).mint(ethers.ZeroAddress, ethers.parseEther("100"))
      ).to.be.revertedWithCustomError(controller, "InvalidAddress");
    });

    it("should revert when minting exceeds MAX_SUPPLY", async function () {
      const { controller, token, deployer, minter, recipient } = await loadFixture(deployFixture);

      // Mint directly on OmniCoin to bring supply close to cap
      // This bypasses the MintController's epoch limit
      const maxSupply = await controller.maxSupplyCap();
      const currentSupply = await token.totalSupply();
      // Leave only 50M remaining (within one epoch limit of 100M)
      const directMintAmount = maxSupply - currentSupply - ethers.parseEther("50000000");
      await token.connect(deployer).mint(recipient.address, directMintAmount);

      // Now remaining via controller is 50M, within epoch limit
      const remaining = await controller.remainingMintable();

      // Try to mint 1 more than remaining
      await expect(
        controller.connect(minter).mint(recipient.address, remaining + 1n)
      ).to.be.revertedWithCustomError(controller, "MaxSupplyExceeded")
        .withArgs(remaining + 1n, remaining);
    });

    it("should allow minting exactly to the cap", async function () {
      const { controller, token, deployer, minter, recipient } = await loadFixture(deployFixture);

      // Mint directly on OmniCoin to bring supply close to cap
      const maxSupply = await controller.maxSupplyCap();
      const currentSupply = await token.totalSupply();
      // Leave only 50M remaining (within one epoch limit of 100M)
      const directMintAmount = maxSupply - currentSupply - ethers.parseEther("50000000");
      await token.connect(deployer).mint(recipient.address, directMintAmount);

      const remaining = await controller.remainingMintable();

      // This should succeed — minting exactly up to the cap
      await controller.connect(minter).mint(recipient.address, remaining);

      expect(await controller.remainingMintable()).to.equal(0n);
      expect(await controller.currentSupply()).to.equal(maxSupply);
    });

    it("should revert any mint after cap is reached", async function () {
      const { controller, token, deployer, minter, recipient } = await loadFixture(deployFixture);

      // Mint directly on OmniCoin to bring supply close to cap
      const maxSupply = await controller.maxSupplyCap();
      const currentSupply = await token.totalSupply();
      // Leave only 50M remaining (within one epoch limit of 100M)
      const directMintAmount = maxSupply - currentSupply - ethers.parseEther("50000000");
      await token.connect(deployer).mint(recipient.address, directMintAmount);

      const remaining = await controller.remainingMintable();

      // Mint to cap via controller
      await controller.connect(minter).mint(recipient.address, remaining);

      // Advance to new epoch to reset epoch counter
      await time.increase(3601);

      // Try to mint 1 more
      await expect(
        controller.connect(minter).mint(recipient.address, 1n)
      ).to.be.revertedWithCustomError(controller, "MaxSupplyExceeded")
        .withArgs(1n, 0n);
    });
  });

  describe("Access Control", function () {
    it("should revert when non-minter tries to mint", async function () {
      const { controller, other, recipient } = await loadFixture(deployFixture);
      await expect(
        controller.connect(other).mint(recipient.address, ethers.parseEther("100"))
      ).to.be.reverted;
    });

    it("should allow admin to grant and revoke minter role", async function () {
      const { controller, deployer, other, recipient, CONTROLLER_MINTER_ROLE } = await loadFixture(deployFixture);

      // Grant MINTER_ROLE to other
      await controller.connect(deployer).grantRole(CONTROLLER_MINTER_ROLE, other.address);
      expect(await controller.hasRole(CONTROLLER_MINTER_ROLE, other.address)).to.be.true;

      // other can now mint
      await controller.connect(other).mint(recipient.address, ethers.parseEther("100"));

      // Revoke MINTER_ROLE from other
      await controller.connect(deployer).revokeRole(CONTROLLER_MINTER_ROLE, other.address);
      expect(await controller.hasRole(CONTROLLER_MINTER_ROLE, other.address)).to.be.false;

      // other can no longer mint
      await expect(
        controller.connect(other).mint(recipient.address, ethers.parseEther("100"))
      ).to.be.reverted;
    });
  });
});
