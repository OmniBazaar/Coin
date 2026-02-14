const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniFractionalNFT", function () {
  let fractional;
  let mockNFT;
  let mockERC20;
  let owner, feeRecipient, user1, user2, user3;

  const CREATION_FEE_BPS = 100; // 1%
  const TOTAL_SHARES = ethers.parseEther("1000"); // 1000 fraction tokens
  const NFT_TOKEN_ID = 1n;
  const FRACTION_NAME = "Fractional CryptoPunk #1";
  const FRACTION_SYMBOL = "fPUNK1";

  beforeEach(async function () {
    [owner, feeRecipient, user1, user2, user3] = await ethers.getSigners();

    // Deploy mock NFT collection
    const MockERC721 = await ethers.getContractFactory("MockERC721");
    mockNFT = await MockERC721.deploy("MockPunks", "MPUNK");

    // Deploy mock ERC20 payment token
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockERC20 = await MockERC20.deploy("Mock USDC", "mUSDC");

    // Deploy OmniFractionalNFT
    const OmniFractionalNFT = await ethers.getContractFactory("OmniFractionalNFT");
    fractional = await OmniFractionalNFT.deploy(
      feeRecipient.address,
      CREATION_FEE_BPS
    );
  });

  /**
   * Helper: mint an NFT to `to`, approve fractional contract, then fractionalize.
   * Returns { vaultId, fractionToken }.
   */
  async function mintAndFractionalize(to, tokenId = NFT_TOKEN_ID, shares = TOTAL_SHARES) {
    // Mint NFT to the user
    await mockNFT.mint(to.address, tokenId);

    // Approve the fractional contract to transfer the NFT
    await mockNFT.connect(to).approve(await fractional.getAddress(), tokenId);

    // Fractionalize
    const tx = await fractional.connect(to).fractionalize(
      await mockNFT.getAddress(),
      tokenId,
      shares,
      FRACTION_NAME,
      FRACTION_SYMBOL
    );
    const receipt = await tx.wait();

    // Extract vaultId from the Fractionalized event
    const event = receipt.logs.find(
      (l) => l.fragment && l.fragment.name === "Fractionalized"
    );
    const vaultId = event.args[0];

    // Get the FractionToken contract
    const vault = await fractional.getVault(vaultId);
    const fractionToken = await ethers.getContractAt("FractionToken", vault.fractionToken);

    return { vaultId, fractionToken, tx };
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 1. Deployment
  // ─────────────────────────────────────────────────────────────────────────

  describe("Deployment", function () {
    it("Should set the correct owner", async function () {
      expect(await fractional.owner()).to.equal(owner.address);
    });

    it("Should set the correct fee recipient", async function () {
      expect(await fractional.feeRecipient()).to.equal(feeRecipient.address);
    });

    it("Should set the correct creation fee", async function () {
      expect(await fractional.creationFeeBps()).to.equal(CREATION_FEE_BPS);
    });

    it("Should start with nextVaultId at 0", async function () {
      expect(await fractional.nextVaultId()).to.equal(0);
    });

    it("Should reject creation fee above MAX_CREATION_FEE_BPS (500)", async function () {
      const OmniFractionalNFT = await ethers.getContractFactory("OmniFractionalNFT");
      await expect(
        OmniFractionalNFT.deploy(feeRecipient.address, 501)
      ).to.be.revertedWithCustomError(fractional, "FeeTooHigh");
    });

    it("Should allow creation fee exactly at MAX_CREATION_FEE_BPS (500)", async function () {
      const OmniFractionalNFT = await ethers.getContractFactory("OmniFractionalNFT");
      const maxFee = await OmniFractionalNFT.deploy(feeRecipient.address, 500);
      expect(await maxFee.creationFeeBps()).to.equal(500);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. Fractionalize
  // ─────────────────────────────────────────────────────────────────────────

  describe("Fractionalize", function () {
    it("Should lock the NFT in the contract", async function () {
      const { vaultId } = await mintAndFractionalize(user1);

      // NFT should now be owned by the fractional contract
      expect(await mockNFT.ownerOf(NFT_TOKEN_ID)).to.equal(
        await fractional.getAddress()
      );
    });

    it("Should deploy a FractionToken with correct name and symbol", async function () {
      const { fractionToken } = await mintAndFractionalize(user1);

      expect(await fractionToken.name()).to.equal(FRACTION_NAME);
      expect(await fractionToken.symbol()).to.equal(FRACTION_SYMBOL);
    });

    it("Should mint all shares to the NFT owner", async function () {
      const { fractionToken } = await mintAndFractionalize(user1);

      expect(await fractionToken.balanceOf(user1.address)).to.equal(TOTAL_SHARES);
      expect(await fractionToken.totalSupply()).to.equal(TOTAL_SHARES);
    });

    it("Should emit a Fractionalized event with correct parameters", async function () {
      await mockNFT.mint(user1.address, NFT_TOKEN_ID);
      await mockNFT.connect(user1).approve(await fractional.getAddress(), NFT_TOKEN_ID);

      await expect(
        fractional.connect(user1).fractionalize(
          await mockNFT.getAddress(),
          NFT_TOKEN_ID,
          TOTAL_SHARES,
          FRACTION_NAME,
          FRACTION_SYMBOL
        )
      )
        .to.emit(fractional, "Fractionalized")
        .withArgs(
          0n, // vaultId
          user1.address,
          await mockNFT.getAddress(),
          NFT_TOKEN_ID,
          // fractionToken address is dynamic — check separately via anyValue
          () => true,
          TOTAL_SHARES
        );
    });

    it("Should reject totalShares of 0", async function () {
      await mockNFT.mint(user1.address, NFT_TOKEN_ID);
      await mockNFT.connect(user1).approve(await fractional.getAddress(), NFT_TOKEN_ID);

      await expect(
        fractional.connect(user1).fractionalize(
          await mockNFT.getAddress(),
          NFT_TOKEN_ID,
          0,
          FRACTION_NAME,
          FRACTION_SYMBOL
        )
      ).to.be.revertedWithCustomError(fractional, "InvalidShareCount");
    });

    it("Should reject totalShares of 1", async function () {
      await mockNFT.mint(user1.address, NFT_TOKEN_ID);
      await mockNFT.connect(user1).approve(await fractional.getAddress(), NFT_TOKEN_ID);

      await expect(
        fractional.connect(user1).fractionalize(
          await mockNFT.getAddress(),
          NFT_TOKEN_ID,
          1,
          FRACTION_NAME,
          FRACTION_SYMBOL
        )
      ).to.be.revertedWithCustomError(fractional, "InvalidShareCount");
    });

    it("Should store vault data correctly", async function () {
      const { vaultId, fractionToken } = await mintAndFractionalize(user1);

      const vault = await fractional.getVault(vaultId);
      expect(vault.owner).to.equal(user1.address);
      expect(vault.collection).to.equal(await mockNFT.getAddress());
      expect(vault.tokenId).to.equal(NFT_TOKEN_ID);
      expect(vault.fractionToken).to.equal(await fractionToken.getAddress());
      expect(vault.totalShares).to.equal(TOTAL_SHARES);
      expect(vault.active).to.equal(true);
      expect(vault.boughtOut).to.equal(false);
    });

    it("Should populate nftToVault lookup", async function () {
      const { vaultId } = await mintAndFractionalize(user1);

      const lookupVaultId = await fractional.getVaultByNFT(
        await mockNFT.getAddress(),
        NFT_TOKEN_ID
      );
      expect(lookupVaultId).to.equal(vaultId);
    });

    it("Should increment nextVaultId after each fractionalization", async function () {
      // First fractionalization
      await mintAndFractionalize(user1, 1n);
      expect(await fractional.nextVaultId()).to.equal(1);

      // Second fractionalization with a different tokenId
      await mintAndFractionalize(user2, 2n);
      expect(await fractional.nextVaultId()).to.equal(2);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. Redeem
  // ─────────────────────────────────────────────────────────────────────────

  describe("Redeem", function () {
    let vaultId;
    let fractionToken;

    beforeEach(async function () {
      const result = await mintAndFractionalize(user1);
      vaultId = result.vaultId;
      fractionToken = result.fractionToken;
    });

    it("Should allow 100% holder to redeem and get NFT back", async function () {
      // user1 holds all shares; approve fractional contract to burn
      await fractionToken.connect(user1).approve(
        await fractional.getAddress(),
        TOTAL_SHARES
      );

      await fractional.connect(user1).redeem(vaultId);

      // NFT should be back with user1
      expect(await mockNFT.ownerOf(NFT_TOKEN_ID)).to.equal(user1.address);
    });

    it("Should burn all fraction tokens on redeem", async function () {
      await fractionToken.connect(user1).approve(
        await fractional.getAddress(),
        TOTAL_SHARES
      );

      await fractional.connect(user1).redeem(vaultId);

      expect(await fractionToken.totalSupply()).to.equal(0);
      expect(await fractionToken.balanceOf(user1.address)).to.equal(0);
    });

    it("Should mark vault as inactive after redeem", async function () {
      await fractionToken.connect(user1).approve(
        await fractional.getAddress(),
        TOTAL_SHARES
      );

      await fractional.connect(user1).redeem(vaultId);

      const vault = await fractional.getVault(vaultId);
      expect(vault.active).to.equal(false);
    });

    it("Should emit Redeemed event", async function () {
      await fractionToken.connect(user1).approve(
        await fractional.getAddress(),
        TOTAL_SHARES
      );

      await expect(fractional.connect(user1).redeem(vaultId))
        .to.emit(fractional, "Redeemed")
        .withArgs(vaultId, user1.address);
    });

    it("Should reject redeem if caller does not hold 100% of shares", async function () {
      // Transfer some shares away
      await fractionToken.connect(user1).transfer(
        user2.address,
        ethers.parseEther("1")
      );

      await fractionToken.connect(user1).approve(
        await fractional.getAddress(),
        TOTAL_SHARES
      );

      await expect(
        fractional.connect(user1).redeem(vaultId)
      ).to.be.revertedWithCustomError(fractional, "InsufficientShares");
    });

    it("Should reject redeem from user with zero shares", async function () {
      await expect(
        fractional.connect(user2).redeem(vaultId)
      ).to.be.revertedWithCustomError(fractional, "InsufficientShares");
    });

    it("Should reject redeem if vault is not active (already redeemed)", async function () {
      await fractionToken.connect(user1).approve(
        await fractional.getAddress(),
        TOTAL_SHARES
      );

      // First redeem succeeds
      await fractional.connect(user1).redeem(vaultId);

      // Second redeem fails
      await expect(
        fractional.connect(user1).redeem(vaultId)
      ).to.be.revertedWithCustomError(fractional, "VaultNotActive");
    });

    it("Should reject redeem for non-existent vault", async function () {
      await expect(
        fractional.connect(user1).redeem(999)
      ).to.be.revertedWithCustomError(fractional, "VaultNotFound");
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. Propose Buyout
  // ─────────────────────────────────────────────────────────────────────────

  describe("Propose Buyout", function () {
    let vaultId;
    let fractionToken;
    const BUYOUT_PRICE = ethers.parseEther("100");

    beforeEach(async function () {
      const result = await mintAndFractionalize(user1);
      vaultId = result.vaultId;
      fractionToken = result.fractionToken;

      // Fund user2 (the buyer) with mock ERC20
      await mockERC20.mint(user2.address, ethers.parseEther("10000"));
    });

    it("Should deposit payment tokens into the contract", async function () {
      await mockERC20.connect(user2).approve(
        await fractional.getAddress(),
        BUYOUT_PRICE
      );

      await fractional.connect(user2).proposeBuyout(
        vaultId,
        BUYOUT_PRICE,
        await mockERC20.getAddress()
      );

      // Contract should hold the buyout price
      const contractBalance = await mockERC20.balanceOf(
        await fractional.getAddress()
      );
      expect(contractBalance).to.equal(BUYOUT_PRICE);
    });

    it("Should record proposer and price in the vault", async function () {
      await mockERC20.connect(user2).approve(
        await fractional.getAddress(),
        BUYOUT_PRICE
      );

      await fractional.connect(user2).proposeBuyout(
        vaultId,
        BUYOUT_PRICE,
        await mockERC20.getAddress()
      );

      // Read vault via the public mapping (returns individual fields)
      const vault = await fractional.vaults(vaultId);
      expect(vault.buyoutProposer).to.equal(user2.address);
      expect(vault.buyoutPrice).to.equal(BUYOUT_PRICE);
      expect(vault.buyoutCurrency).to.equal(await mockERC20.getAddress());
    });

    it("Should emit BuyoutProposed event", async function () {
      await mockERC20.connect(user2).approve(
        await fractional.getAddress(),
        BUYOUT_PRICE
      );

      await expect(
        fractional.connect(user2).proposeBuyout(
          vaultId,
          BUYOUT_PRICE,
          await mockERC20.getAddress()
        )
      )
        .to.emit(fractional, "BuyoutProposed")
        .withArgs(vaultId, user2.address, BUYOUT_PRICE);
    });

    it("Should reject if vault is not active", async function () {
      // Redeem the vault first
      await fractionToken.connect(user1).approve(
        await fractional.getAddress(),
        TOTAL_SHARES
      );
      await fractional.connect(user1).redeem(vaultId);

      await mockERC20.connect(user2).approve(
        await fractional.getAddress(),
        BUYOUT_PRICE
      );

      await expect(
        fractional.connect(user2).proposeBuyout(
          vaultId,
          BUYOUT_PRICE,
          await mockERC20.getAddress()
        )
      ).to.be.revertedWithCustomError(fractional, "VaultNotActive");
    });

    it("Should reject if buyout already proposed", async function () {
      await mockERC20.connect(user2).approve(
        await fractional.getAddress(),
        BUYOUT_PRICE * 2n
      );

      // First proposal succeeds
      await fractional.connect(user2).proposeBuyout(
        vaultId,
        BUYOUT_PRICE,
        await mockERC20.getAddress()
      );

      // Second proposal fails
      await expect(
        fractional.connect(user2).proposeBuyout(
          vaultId,
          BUYOUT_PRICE,
          await mockERC20.getAddress()
        )
      ).to.be.revertedWithCustomError(fractional, "BuyoutAlreadyActive");
    });

    it("Should reject zero price", async function () {
      await expect(
        fractional.connect(user2).proposeBuyout(
          vaultId,
          0,
          await mockERC20.getAddress()
        )
      ).to.be.revertedWithCustomError(fractional, "ZeroBuyoutPrice");
    });

    it("Should reject if vault does not exist", async function () {
      await expect(
        fractional.connect(user2).proposeBuyout(
          999,
          BUYOUT_PRICE,
          await mockERC20.getAddress()
        )
      ).to.be.revertedWithCustomError(fractional, "VaultNotFound");
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 5. Execute Buyout
  // ─────────────────────────────────────────────────────────────────────────

  describe("Execute Buyout", function () {
    let vaultId;
    let fractionToken;
    const BUYOUT_PRICE = ethers.parseEther("100");

    beforeEach(async function () {
      const result = await mintAndFractionalize(user1);
      vaultId = result.vaultId;
      fractionToken = result.fractionToken;

      // Fund user2 (buyer) and propose buyout
      await mockERC20.mint(user2.address, ethers.parseEther("10000"));
      await mockERC20.connect(user2).approve(
        await fractional.getAddress(),
        BUYOUT_PRICE
      );
      await fractional.connect(user2).proposeBuyout(
        vaultId,
        BUYOUT_PRICE,
        await mockERC20.getAddress()
      );
    });

    it("Should allow share holder to burn all shares and receive full payment", async function () {
      // user1 holds all shares
      await fractionToken.connect(user1).approve(
        await fractional.getAddress(),
        TOTAL_SHARES
      );

      const balanceBefore = await mockERC20.balanceOf(user1.address);

      await fractional.connect(user1).executeBuyout(vaultId, TOTAL_SHARES);

      const balanceAfter = await mockERC20.balanceOf(user1.address);
      expect(balanceAfter - balanceBefore).to.equal(BUYOUT_PRICE);
    });

    it("Should transfer NFT to proposer when all shares are burned", async function () {
      await fractionToken.connect(user1).approve(
        await fractional.getAddress(),
        TOTAL_SHARES
      );

      await fractional.connect(user1).executeBuyout(vaultId, TOTAL_SHARES);

      // NFT should go to the buyout proposer (user2)
      expect(await mockNFT.ownerOf(NFT_TOKEN_ID)).to.equal(user2.address);
    });

    it("Should mark vault as inactive and boughtOut when all shares burned", async function () {
      await fractionToken.connect(user1).approve(
        await fractional.getAddress(),
        TOTAL_SHARES
      );

      await fractional.connect(user1).executeBuyout(vaultId, TOTAL_SHARES);

      const vault = await fractional.getVault(vaultId);
      expect(vault.active).to.equal(false);
      expect(vault.boughtOut).to.equal(true);
    });

    it("Should emit BuyoutExecuted when all shares burned", async function () {
      await fractionToken.connect(user1).approve(
        await fractional.getAddress(),
        TOTAL_SHARES
      );

      await expect(
        fractional.connect(user1).executeBuyout(vaultId, TOTAL_SHARES)
      )
        .to.emit(fractional, "BuyoutExecuted")
        .withArgs(vaultId, user2.address);
    });

    it("Should reject if no buyout proposal exists", async function () {
      // Create a new vault without a buyout proposal
      const { vaultId: freshVaultId, fractionToken: freshToken } =
        await mintAndFractionalize(user1, 42n);

      await freshToken.connect(user1).approve(
        await fractional.getAddress(),
        TOTAL_SHARES
      );

      await expect(
        fractional.connect(user1).executeBuyout(freshVaultId, TOTAL_SHARES)
      ).to.be.revertedWithCustomError(fractional, "NoBuyoutProposal");
    });

    it("Should reject if caller has insufficient shares", async function () {
      // user3 has no shares
      await expect(
        fractional.connect(user3).executeBuyout(vaultId, ethers.parseEther("1"))
      ).to.be.revertedWithCustomError(fractional, "InsufficientShares");
    });

    it("Should reject if vault does not exist", async function () {
      await expect(
        fractional.connect(user1).executeBuyout(999, 1)
      ).to.be.revertedWithCustomError(fractional, "VaultNotFound");
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 6. Partial Buyout
  // ─────────────────────────────────────────────────────────────────────────

  describe("Partial Buyout", function () {
    let vaultId;
    let fractionToken;
    const BUYOUT_PRICE = ethers.parseEther("100");

    beforeEach(async function () {
      const result = await mintAndFractionalize(user1);
      vaultId = result.vaultId;
      fractionToken = result.fractionToken;

      // Distribute shares: user1 keeps 600, user2 gets 400
      await fractionToken.connect(user1).transfer(
        user2.address,
        ethers.parseEther("400")
      );

      // Fund user3 (buyer) and propose buyout
      await mockERC20.mint(user3.address, ethers.parseEther("10000"));
      await mockERC20.connect(user3).approve(
        await fractional.getAddress(),
        BUYOUT_PRICE
      );
      await fractional.connect(user3).proposeBuyout(
        vaultId,
        BUYOUT_PRICE,
        await mockERC20.getAddress()
      );
    });

    it("Should pay proportional amount for partial share sale", async function () {
      const sharesToSell = ethers.parseEther("400"); // 400 of 1000 = 40%
      const expectedPayment = (BUYOUT_PRICE * sharesToSell) / TOTAL_SHARES;

      await fractionToken.connect(user2).approve(
        await fractional.getAddress(),
        sharesToSell
      );

      const balanceBefore = await mockERC20.balanceOf(user2.address);
      await fractional.connect(user2).executeBuyout(vaultId, sharesToSell);
      const balanceAfter = await mockERC20.balanceOf(user2.address);

      expect(balanceAfter - balanceBefore).to.equal(expectedPayment);
    });

    it("Should keep vault active after partial sale", async function () {
      const sharesToSell = ethers.parseEther("400");

      await fractionToken.connect(user2).approve(
        await fractional.getAddress(),
        sharesToSell
      );

      await fractional.connect(user2).executeBuyout(vaultId, sharesToSell);

      const vault = await fractional.getVault(vaultId);
      expect(vault.active).to.equal(true);
      expect(vault.boughtOut).to.equal(false);
    });

    it("Should not transfer NFT after partial sale", async function () {
      const sharesToSell = ethers.parseEther("400");

      await fractionToken.connect(user2).approve(
        await fractional.getAddress(),
        sharesToSell
      );

      await fractional.connect(user2).executeBuyout(vaultId, sharesToSell);

      // NFT should still be in the fractional contract
      expect(await mockNFT.ownerOf(NFT_TOKEN_ID)).to.equal(
        await fractional.getAddress()
      );
    });

    it("Should burn the sold shares", async function () {
      const sharesToSell = ethers.parseEther("400");

      await fractionToken.connect(user2).approve(
        await fractional.getAddress(),
        sharesToSell
      );

      await fractional.connect(user2).executeBuyout(vaultId, sharesToSell);

      expect(await fractionToken.balanceOf(user2.address)).to.equal(0);
      expect(await fractionToken.totalSupply()).to.equal(
        ethers.parseEther("600")
      );
    });

    it("Should complete buyout when second holder also sells remaining shares", async function () {
      // user2 sells 400 shares
      const user2Shares = ethers.parseEther("400");
      await fractionToken.connect(user2).approve(
        await fractional.getAddress(),
        user2Shares
      );
      await fractional.connect(user2).executeBuyout(vaultId, user2Shares);

      // Vault still active
      let vault = await fractional.getVault(vaultId);
      expect(vault.active).to.equal(true);

      // user1 sells remaining 600 shares
      const user1Shares = ethers.parseEther("600");
      await fractionToken.connect(user1).approve(
        await fractional.getAddress(),
        user1Shares
      );

      await expect(
        fractional.connect(user1).executeBuyout(vaultId, user1Shares)
      )
        .to.emit(fractional, "BuyoutExecuted")
        .withArgs(vaultId, user3.address);

      // Now the vault should be inactive and boughtOut
      vault = await fractional.getVault(vaultId);
      expect(vault.active).to.equal(false);
      expect(vault.boughtOut).to.equal(true);

      // NFT should be with user3 (the proposer)
      expect(await mockNFT.ownerOf(NFT_TOKEN_ID)).to.equal(user3.address);
    });

    it("Should distribute correct pro-rata amounts to multiple holders", async function () {
      // user2 has 400/1000 shares, user1 has 600/1000 shares
      const user2Shares = ethers.parseEther("400");
      const user1Shares = ethers.parseEther("600");
      const expectedUser2Payment = (BUYOUT_PRICE * user2Shares) / TOTAL_SHARES;
      const expectedUser1Payment = (BUYOUT_PRICE * user1Shares) / TOTAL_SHARES;

      // user2 sells
      await fractionToken.connect(user2).approve(
        await fractional.getAddress(),
        user2Shares
      );
      const u2Before = await mockERC20.balanceOf(user2.address);
      await fractional.connect(user2).executeBuyout(vaultId, user2Shares);
      const u2After = await mockERC20.balanceOf(user2.address);
      expect(u2After - u2Before).to.equal(expectedUser2Payment);

      // user1 sells
      await fractionToken.connect(user1).approve(
        await fractional.getAddress(),
        user1Shares
      );
      const u1Before = await mockERC20.balanceOf(user1.address);
      await fractional.connect(user1).executeBuyout(vaultId, user1Shares);
      const u1After = await mockERC20.balanceOf(user1.address);
      expect(u1After - u1Before).to.equal(expectedUser1Payment);

      // Total paid out should equal buyout price
      expect(expectedUser1Payment + expectedUser2Payment).to.equal(BUYOUT_PRICE);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 7. Admin Functions
  // ─────────────────────────────────────────────────────────────────────────

  describe("Admin", function () {
    describe("setCreationFee", function () {
      it("Should allow owner to update creation fee", async function () {
        await fractional.connect(owner).setCreationFee(200);
        expect(await fractional.creationFeeBps()).to.equal(200);
      });

      it("Should allow setting fee to zero", async function () {
        await fractional.connect(owner).setCreationFee(0);
        expect(await fractional.creationFeeBps()).to.equal(0);
      });

      it("Should allow setting fee to MAX_CREATION_FEE_BPS (500)", async function () {
        await fractional.connect(owner).setCreationFee(500);
        expect(await fractional.creationFeeBps()).to.equal(500);
      });

      it("Should reject fee above MAX_CREATION_FEE_BPS", async function () {
        await expect(
          fractional.connect(owner).setCreationFee(501)
        ).to.be.revertedWithCustomError(fractional, "FeeTooHigh");
      });

      it("Should reject non-owner caller", async function () {
        await expect(
          fractional.connect(user1).setCreationFee(200)
        ).to.be.revertedWithCustomError(fractional, "OwnableUnauthorizedAccount");
      });
    });

    describe("setFeeRecipient", function () {
      it("Should allow owner to update fee recipient", async function () {
        await fractional.connect(owner).setFeeRecipient(user3.address);
        expect(await fractional.feeRecipient()).to.equal(user3.address);
      });

      it("Should reject non-owner caller", async function () {
        await expect(
          fractional.connect(user1).setFeeRecipient(user3.address)
        ).to.be.revertedWithCustomError(fractional, "OwnableUnauthorizedAccount");
      });
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 8. View Functions
  // ─────────────────────────────────────────────────────────────────────────

  describe("View Functions", function () {
    it("getVault should return all vault fields correctly", async function () {
      const { vaultId, fractionToken } = await mintAndFractionalize(user1);

      const vault = await fractional.getVault(vaultId);
      expect(vault.owner).to.equal(user1.address);
      expect(vault.collection).to.equal(await mockNFT.getAddress());
      expect(vault.tokenId).to.equal(NFT_TOKEN_ID);
      expect(vault.fractionToken).to.equal(await fractionToken.getAddress());
      expect(vault.totalShares).to.equal(TOTAL_SHARES);
      expect(vault.active).to.equal(true);
      expect(vault.boughtOut).to.equal(false);
    });

    it("getVault should return zero values for non-existent vault", async function () {
      const vault = await fractional.getVault(999);
      expect(vault.owner).to.equal(ethers.ZeroAddress);
      expect(vault.collection).to.equal(ethers.ZeroAddress);
      expect(vault.tokenId).to.equal(0);
      expect(vault.fractionToken).to.equal(ethers.ZeroAddress);
      expect(vault.totalShares).to.equal(0);
      expect(vault.active).to.equal(false);
      expect(vault.boughtOut).to.equal(false);
    });

    it("getVaultByNFT should return the correct vault ID", async function () {
      const { vaultId } = await mintAndFractionalize(user1);
      const nftAddr = await mockNFT.getAddress();

      const result = await fractional.getVaultByNFT(nftAddr, NFT_TOKEN_ID);
      expect(result).to.equal(vaultId);
    });

    it("getVaultByNFT should return 0 for unregistered NFT", async function () {
      const nftAddr = await mockNFT.getAddress();
      const result = await fractional.getVaultByNFT(nftAddr, 99999);
      expect(result).to.equal(0);
    });

    it("getVault should reflect inactive state after redeem", async function () {
      const { vaultId, fractionToken } = await mintAndFractionalize(user1);

      await fractionToken.connect(user1).approve(
        await fractional.getAddress(),
        TOTAL_SHARES
      );
      await fractional.connect(user1).redeem(vaultId);

      const vault = await fractional.getVault(vaultId);
      expect(vault.active).to.equal(false);
      expect(vault.boughtOut).to.equal(false);
    });

    it("getVault should reflect boughtOut state after complete buyout", async function () {
      const { vaultId, fractionToken } = await mintAndFractionalize(user1);

      await mockERC20.mint(user2.address, ethers.parseEther("10000"));
      const buyoutPrice = ethers.parseEther("50");
      await mockERC20.connect(user2).approve(
        await fractional.getAddress(),
        buyoutPrice
      );
      await fractional.connect(user2).proposeBuyout(
        vaultId,
        buyoutPrice,
        await mockERC20.getAddress()
      );

      await fractionToken.connect(user1).approve(
        await fractional.getAddress(),
        TOTAL_SHARES
      );
      await fractional.connect(user1).executeBuyout(vaultId, TOTAL_SHARES);

      const vault = await fractional.getVault(vaultId);
      expect(vault.active).to.equal(false);
      expect(vault.boughtOut).to.equal(true);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 9. FractionToken
  // ─────────────────────────────────────────────────────────────────────────

  describe("FractionToken", function () {
    let fractionToken;
    let vaultId;

    beforeEach(async function () {
      const result = await mintAndFractionalize(user1);
      vaultId = result.vaultId;
      fractionToken = result.fractionToken;
    });

    it("Should have the correct name", async function () {
      expect(await fractionToken.name()).to.equal(FRACTION_NAME);
    });

    it("Should have the correct symbol", async function () {
      expect(await fractionToken.symbol()).to.equal(FRACTION_SYMBOL);
    });

    it("Should store the vault address as immutable", async function () {
      expect(await fractionToken.vault()).to.equal(
        await fractional.getAddress()
      );
    });

    it("Should have 18 decimals (ERC-20 default)", async function () {
      expect(await fractionToken.decimals()).to.equal(18);
    });

    it("Should allow standard ERC-20 transfers between users", async function () {
      const amount = ethers.parseEther("250");
      await fractionToken.connect(user1).transfer(user2.address, amount);

      expect(await fractionToken.balanceOf(user1.address)).to.equal(
        TOTAL_SHARES - amount
      );
      expect(await fractionToken.balanceOf(user2.address)).to.equal(amount);
    });

    it("Should support approve and transferFrom", async function () {
      const amount = ethers.parseEther("100");

      await fractionToken.connect(user1).approve(user2.address, amount);
      expect(await fractionToken.allowance(user1.address, user2.address)).to.equal(amount);

      await fractionToken.connect(user2).transferFrom(
        user1.address,
        user3.address,
        amount
      );
      expect(await fractionToken.balanceOf(user3.address)).to.equal(amount);
    });

    it("Should support burnFrom with approval (used by vault during redeem)", async function () {
      const burnAmount = ethers.parseEther("500");

      // user1 approves user2 to burn on their behalf
      await fractionToken.connect(user1).approve(user2.address, burnAmount);

      await fractionToken.connect(user2).burnFrom(user1.address, burnAmount);

      expect(await fractionToken.balanceOf(user1.address)).to.equal(
        TOTAL_SHARES - burnAmount
      );
      expect(await fractionToken.totalSupply()).to.equal(
        TOTAL_SHARES - burnAmount
      );
    });

    it("Should reject burnFrom without sufficient approval", async function () {
      await expect(
        fractionToken.connect(user2).burnFrom(user1.address, ethers.parseEther("1"))
      ).to.be.revertedWithCustomError(fractionToken, "ERC20InsufficientAllowance");
    });

    it("Should support direct burn by token holder", async function () {
      const burnAmount = ethers.parseEther("200");
      await fractionToken.connect(user1).burn(burnAmount);

      expect(await fractionToken.balanceOf(user1.address)).to.equal(
        TOTAL_SHARES - burnAmount
      );
      expect(await fractionToken.totalSupply()).to.equal(
        TOTAL_SHARES - burnAmount
      );
    });
  });
});
