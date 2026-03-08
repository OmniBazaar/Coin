const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * @title OmniTreasury Test Suite
 * @notice Comprehensive tests for the Protocol-Owned Liquidity wallet.
 * @dev Tests cover:
 *   1.  Deployment — correct role assignments, zero-address rejection
 *   2.  Native reception — receive() accepts XOM, emits event
 *   3.  ERC-20 transfers — transferToken() moves tokens, guards
 *   4.  Native transfers — transferNative() sends XOM, guards
 *   5.  Token approvals — approveToken() sets allowance
 *   6.  NFT transfers — transferNFT() and transferERC1155()
 *   7.  Execute — low-level call, self-call rejection, revert handling
 *   8.  ExecuteBatch — multiple calls, array mismatch, partial failure
 *   9.  Access control — non-governance accounts are rejected
 *  10.  Pause/unpause — guardian controls, governance blocked when paused
 *  11.  Reentrancy — malicious callback cannot re-enter
 *  12.  supportsInterface — AccessControl, ERC721Receiver, ERC1155Receiver
 */
describe("OmniTreasury", function () {
  let treasury, token, nft, erc1155;
  let admin, governance, guardian, recipient, attacker;

  const MINT_AMOUNT = ethers.parseEther("100000");
  const TRANSFER_AMOUNT = ethers.parseEther("1000");
  const ONE_XOM = ethers.parseEther("1");

  /**
   * Deploy fresh OmniTreasury, MockERC20, MockERC721, and MockERC1155
   * before each test.
   */
  beforeEach(async function () {
    const signers = await ethers.getSigners();
    admin = signers[0];
    governance = signers[1];
    guardian = signers[2];
    recipient = signers[3];
    attacker = signers[4];

    // Deploy OmniTreasury with admin
    const Treasury = await ethers.getContractFactory("OmniTreasury");
    treasury = await Treasury.deploy(admin.address);
    await treasury.waitForDeployment();

    // Grant GOVERNANCE_ROLE to governance signer
    const GOVERNANCE_ROLE = await treasury.GOVERNANCE_ROLE();
    await treasury.connect(admin).grantRole(GOVERNANCE_ROLE, governance.address);

    // Grant GUARDIAN_ROLE to guardian signer
    const GUARDIAN_ROLE = await treasury.GUARDIAN_ROLE();
    await treasury.connect(admin).grantRole(GUARDIAN_ROLE, guardian.address);

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    token = await MockERC20.deploy("OmniCoin", "XOM");
    await token.waitForDeployment();

    const MockERC721 = await ethers.getContractFactory("MockERC721");
    nft = await MockERC721.deploy("OmniNFT", "ONFT");
    await nft.waitForDeployment();

    const MockERC1155 = await ethers.getContractFactory("MockERC1155");
    erc1155 = await MockERC1155.deploy();
    await erc1155.waitForDeployment();
  });

  // ═══════════════════════════════════════════════════════════════════
  //  1. Deployment
  // ═══════════════════════════════════════════════════════════════════

  describe("Deployment", function () {
    it("should assign DEFAULT_ADMIN_ROLE to the admin", async function () {
      const DEFAULT_ADMIN = await treasury.DEFAULT_ADMIN_ROLE();
      expect(await treasury.hasRole(DEFAULT_ADMIN, admin.address)).to.be.true;
    });

    it("should assign GOVERNANCE_ROLE to the admin", async function () {
      const GOVERNANCE_ROLE = await treasury.GOVERNANCE_ROLE();
      expect(await treasury.hasRole(GOVERNANCE_ROLE, admin.address)).to.be.true;
    });

    it("should assign GUARDIAN_ROLE to the admin", async function () {
      const GUARDIAN_ROLE = await treasury.GUARDIAN_ROLE();
      expect(await treasury.hasRole(GUARDIAN_ROLE, admin.address)).to.be.true;
    });

    it("should revert deployment with zero address", async function () {
      const Treasury = await ethers.getContractFactory("OmniTreasury");
      await expect(
        Treasury.deploy(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(treasury, "ZeroAddress");
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  2. Native XOM Reception
  // ═══════════════════════════════════════════════════════════════════

  describe("Native XOM Reception", function () {
    it("should accept native XOM and emit NativeReceived", async function () {
      await expect(
        admin.sendTransaction({ to: treasury.target, value: ONE_XOM })
      )
        .to.emit(treasury, "NativeReceived")
        .withArgs(admin.address, ONE_XOM);
    });

    it("should update native balance after receiving XOM", async function () {
      await admin.sendTransaction({ to: treasury.target, value: ONE_XOM });
      expect(await treasury.nativeBalance()).to.equal(ONE_XOM);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  3. ERC-20 Transfers
  // ═══════════════════════════════════════════════════════════════════

  describe("ERC-20 Transfers", function () {
    beforeEach(async function () {
      // Fund treasury with ERC-20 tokens
      await token.mint(treasury.target, MINT_AMOUNT);
    });

    it("should transfer ERC-20 tokens and emit TokenTransferred", async function () {
      await expect(
        treasury.connect(governance).transferToken(
          token.target, recipient.address, TRANSFER_AMOUNT
        )
      )
        .to.emit(treasury, "TokenTransferred")
        .withArgs(token.target, recipient.address, TRANSFER_AMOUNT);

      expect(await token.balanceOf(recipient.address)).to.equal(TRANSFER_AMOUNT);
    });

    it("should update tokenBalance view after transfer", async function () {
      const before = await treasury.tokenBalance(token.target);
      await treasury.connect(governance).transferToken(
        token.target, recipient.address, TRANSFER_AMOUNT
      );
      const after = await treasury.tokenBalance(token.target);
      expect(before - after).to.equal(TRANSFER_AMOUNT);
    });

    it("should revert transferToken to zero address", async function () {
      await expect(
        treasury.connect(governance).transferToken(
          token.target, ethers.ZeroAddress, TRANSFER_AMOUNT
        )
      ).to.be.revertedWithCustomError(treasury, "ZeroAddress");
    });

    it("should revert transferToken with zero amount", async function () {
      await expect(
        treasury.connect(governance).transferToken(
          token.target, recipient.address, 0
        )
      ).to.be.revertedWithCustomError(treasury, "ZeroAmount");
    });

    it("should revert transferToken with zero token address", async function () {
      await expect(
        treasury.connect(governance).transferToken(
          ethers.ZeroAddress, recipient.address, TRANSFER_AMOUNT
        )
      ).to.be.revertedWithCustomError(treasury, "ZeroAddress");
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  4. Native XOM Transfers
  // ═══════════════════════════════════════════════════════════════════

  describe("Native XOM Transfers", function () {
    beforeEach(async function () {
      // Fund treasury with native XOM
      await admin.sendTransaction({
        to: treasury.target,
        value: ethers.parseEther("10"),
      });
    });

    it("should transfer native XOM and emit NativeTransferred", async function () {
      const balanceBefore = await ethers.provider.getBalance(recipient.address);

      await expect(
        treasury.connect(governance).transferNative(
          recipient.address, ONE_XOM
        )
      )
        .to.emit(treasury, "NativeTransferred")
        .withArgs(recipient.address, ONE_XOM);

      const balanceAfter = await ethers.provider.getBalance(recipient.address);
      expect(balanceAfter - balanceBefore).to.equal(ONE_XOM);
    });

    it("should revert transferNative to zero address", async function () {
      await expect(
        treasury.connect(governance).transferNative(ethers.ZeroAddress, ONE_XOM)
      ).to.be.revertedWithCustomError(treasury, "ZeroAddress");
    });

    it("should revert transferNative with zero amount", async function () {
      await expect(
        treasury.connect(governance).transferNative(recipient.address, 0)
      ).to.be.revertedWithCustomError(treasury, "ZeroAmount");
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  5. Token Approvals
  // ═══════════════════════════════════════════════════════════════════

  describe("Token Approvals", function () {
    it("should approve spender and emit TokenApproved", async function () {
      await expect(
        treasury.connect(governance).approveToken(
          token.target, recipient.address, TRANSFER_AMOUNT
        )
      )
        .to.emit(treasury, "TokenApproved")
        .withArgs(token.target, recipient.address, TRANSFER_AMOUNT);

      expect(
        await token.allowance(treasury.target, recipient.address)
      ).to.equal(TRANSFER_AMOUNT);
    });

    it("should allow setting approval to zero", async function () {
      // First set an allowance
      await treasury.connect(governance).approveToken(
        token.target, recipient.address, TRANSFER_AMOUNT
      );
      // Then set to zero
      await treasury.connect(governance).approveToken(
        token.target, recipient.address, 0
      );
      expect(
        await token.allowance(treasury.target, recipient.address)
      ).to.equal(0);
    });

    it("should revert approveToken with zero spender address", async function () {
      await expect(
        treasury.connect(governance).approveToken(
          token.target, ethers.ZeroAddress, TRANSFER_AMOUNT
        )
      ).to.be.revertedWithCustomError(treasury, "ZeroAddress");
    });

    it("should revert approveToken with zero token address", async function () {
      await expect(
        treasury.connect(governance).approveToken(
          ethers.ZeroAddress, recipient.address, TRANSFER_AMOUNT
        )
      ).to.be.revertedWithCustomError(treasury, "ZeroAddress");
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  6. NFT Transfers (ERC-721 & ERC-1155)
  // ═══════════════════════════════════════════════════════════════════

  describe("NFT Transfers", function () {
    const TOKEN_ID = 42n;
    const ERC1155_ID = 7n;
    const ERC1155_AMOUNT = 100n;

    beforeEach(async function () {
      // Mint ERC-721 directly to treasury
      await nft.mint(treasury.target, TOKEN_ID);
      // Mint ERC-1155 directly to treasury
      await erc1155.mint(treasury.target, ERC1155_ID, ERC1155_AMOUNT);
    });

    it("should transfer ERC-721 and emit NFTTransferred", async function () {
      await expect(
        treasury.connect(governance).transferNFT(
          nft.target, recipient.address, TOKEN_ID
        )
      )
        .to.emit(treasury, "NFTTransferred")
        .withArgs(nft.target, recipient.address, TOKEN_ID);

      expect(await nft.ownerOf(TOKEN_ID)).to.equal(recipient.address);
    });

    it("should revert transferNFT to zero address", async function () {
      await expect(
        treasury.connect(governance).transferNFT(
          nft.target, ethers.ZeroAddress, TOKEN_ID
        )
      ).to.be.revertedWithCustomError(treasury, "ZeroAddress");
    });

    it("should revert transferNFT with zero nft address", async function () {
      await expect(
        treasury.connect(governance).transferNFT(
          ethers.ZeroAddress, recipient.address, TOKEN_ID
        )
      ).to.be.revertedWithCustomError(treasury, "ZeroAddress");
    });

    it("should transfer ERC-1155 and emit ERC1155Transferred", async function () {
      await expect(
        treasury.connect(governance).transferERC1155(
          erc1155.target, recipient.address, ERC1155_ID, ERC1155_AMOUNT, "0x"
        )
      )
        .to.emit(treasury, "ERC1155Transferred")
        .withArgs(
          erc1155.target, recipient.address, ERC1155_ID, ERC1155_AMOUNT
        );

      expect(
        await erc1155.balanceOf(recipient.address, ERC1155_ID)
      ).to.equal(ERC1155_AMOUNT);
    });

    it("should revert transferERC1155 to zero address", async function () {
      await expect(
        treasury.connect(governance).transferERC1155(
          erc1155.target, ethers.ZeroAddress, ERC1155_ID, ERC1155_AMOUNT, "0x"
        )
      ).to.be.revertedWithCustomError(treasury, "ZeroAddress");
    });

    it("should revert transferERC1155 with zero amount", async function () {
      await expect(
        treasury.connect(governance).transferERC1155(
          erc1155.target, recipient.address, ERC1155_ID, 0, "0x"
        )
      ).to.be.revertedWithCustomError(treasury, "ZeroAmount");
    });

    it("should revert transferERC1155 with zero token address", async function () {
      await expect(
        treasury.connect(governance).transferERC1155(
          ethers.ZeroAddress, recipient.address, ERC1155_ID, ERC1155_AMOUNT, "0x"
        )
      ).to.be.revertedWithCustomError(treasury, "ZeroAddress");
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  7. Execute (Low-Level Call)
  // ═══════════════════════════════════════════════════════════════════

  describe("Execute", function () {
    it("should execute a low-level call and emit Executed", async function () {
      // Mint tokens to treasury, then use execute() to transfer them
      await token.mint(treasury.target, MINT_AMOUNT);

      const calldata = token.interface.encodeFunctionData(
        "transfer", [recipient.address, TRANSFER_AMOUNT]
      );

      await expect(
        treasury.connect(governance).execute(token.target, 0, calldata)
      )
        .to.emit(treasury, "Executed")
        .withArgs(token.target, 0, calldata);

      expect(await token.balanceOf(recipient.address)).to.equal(TRANSFER_AMOUNT);
    });

    it("should forward native XOM with execute()", async function () {
      // Fund treasury with native XOM
      await admin.sendTransaction({
        to: treasury.target,
        value: ethers.parseEther("5"),
      });

      const balanceBefore = await ethers.provider.getBalance(recipient.address);

      // Execute call with value to recipient (empty calldata)
      await treasury.connect(governance).execute(
        recipient.address, ONE_XOM, "0x"
      );

      const balanceAfter = await ethers.provider.getBalance(recipient.address);
      expect(balanceAfter - balanceBefore).to.equal(ONE_XOM);
    });

    it("should revert execute() targeting self", async function () {
      await expect(
        treasury.connect(governance).execute(treasury.target, 0, "0x")
      ).to.be.revertedWithCustomError(treasury, "SelfCallNotAllowed");
    });

    it("should revert execute() targeting zero address", async function () {
      await expect(
        treasury.connect(governance).execute(ethers.ZeroAddress, 0, "0x")
      ).to.be.revertedWithCustomError(treasury, "ZeroAddress");
    });

    it("should revert execute() when callee reverts", async function () {
      // Call a non-existent function on the token contract
      const badCalldata = "0xdeadbeef";
      await expect(
        treasury.connect(governance).execute(token.target, 0, badCalldata)
      ).to.be.revertedWithCustomError(treasury, "ExecutionFailed");
    });

    it("should return call data from execute()", async function () {
      await token.mint(treasury.target, MINT_AMOUNT);

      const calldata = token.interface.encodeFunctionData(
        "balanceOf", [treasury.target]
      );

      const result = await treasury.connect(governance).execute.staticCall(
        token.target, 0, calldata
      );

      // Decode the returned balance
      const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
        ["uint256"], result
      );
      expect(decoded[0]).to.equal(MINT_AMOUNT);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  8. ExecuteBatch
  // ═══════════════════════════════════════════════════════════════════

  describe("ExecuteBatch", function () {
    it("should execute multiple calls in batch", async function () {
      // Mint tokens to treasury
      await token.mint(treasury.target, MINT_AMOUNT);

      // Batch: two transfers to two different recipients
      const calldata1 = token.interface.encodeFunctionData(
        "transfer", [recipient.address, TRANSFER_AMOUNT]
      );
      const calldata2 = token.interface.encodeFunctionData(
        "transfer", [attacker.address, TRANSFER_AMOUNT]
      );

      await expect(
        treasury.connect(governance).executeBatch(
          [token.target, token.target],
          [0, 0],
          [calldata1, calldata2]
        )
      )
        .to.emit(treasury, "BatchExecuted")
        .withArgs(2);

      expect(await token.balanceOf(recipient.address)).to.equal(TRANSFER_AMOUNT);
      expect(await token.balanceOf(attacker.address)).to.equal(TRANSFER_AMOUNT);
    });

    it("should revert on array length mismatch", async function () {
      await expect(
        treasury.connect(governance).executeBatch(
          [token.target],
          [0, 0],  // mismatched length
          ["0x"]
        )
      ).to.be.revertedWithCustomError(treasury, "ArrayLengthMismatch");
    });

    it("should revert batch with self-call target", async function () {
      await expect(
        treasury.connect(governance).executeBatch(
          [treasury.target],
          [0],
          ["0x"]
        )
      ).to.be.revertedWithCustomError(treasury, "SelfCallNotAllowed");
    });

    it("should revert batch with zero address target", async function () {
      await expect(
        treasury.connect(governance).executeBatch(
          [ethers.ZeroAddress],
          [0],
          ["0x"]
        )
      ).to.be.revertedWithCustomError(treasury, "ZeroAddress");
    });

    it("should revert on partial failure in batch", async function () {
      await token.mint(treasury.target, MINT_AMOUNT);

      // First call succeeds, second call reverts
      const goodCalldata = token.interface.encodeFunctionData(
        "transfer", [recipient.address, TRANSFER_AMOUNT]
      );
      const badCalldata = "0xdeadbeef";

      await expect(
        treasury.connect(governance).executeBatch(
          [token.target, token.target],
          [0, 0],
          [goodCalldata, badCalldata]
        )
      ).to.be.revertedWithCustomError(treasury, "ExecutionFailed");
    });

    it("should handle empty batch (zero length)", async function () {
      await expect(
        treasury.connect(governance).executeBatch([], [], [])
      )
        .to.emit(treasury, "BatchExecuted")
        .withArgs(0);
    });

    it("should revert when batch exceeds MAX_BATCH_SIZE", async function () {
      const SIZE = 65; // MAX_BATCH_SIZE is 64
      const targets = Array(SIZE).fill(token.target);
      const values = Array(SIZE).fill(0);
      const calldatas = Array(SIZE).fill("0x");

      await expect(
        treasury.connect(governance).executeBatch(targets, values, calldatas)
      ).to.be.revertedWithCustomError(treasury, "BatchTooLarge");
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  9. Access Control
  // ═══════════════════════════════════════════════════════════════════

  describe("Access Control", function () {
    beforeEach(async function () {
      await token.mint(treasury.target, MINT_AMOUNT);
      await admin.sendTransaction({
        to: treasury.target,
        value: ethers.parseEther("10"),
      });
    });

    it("should reject transferToken from non-governance", async function () {
      await expect(
        treasury.connect(attacker).transferToken(
          token.target, attacker.address, TRANSFER_AMOUNT
        )
      ).to.be.reverted;
    });

    it("should reject transferNative from non-governance", async function () {
      await expect(
        treasury.connect(attacker).transferNative(attacker.address, ONE_XOM)
      ).to.be.reverted;
    });

    it("should reject approveToken from non-governance", async function () {
      await expect(
        treasury.connect(attacker).approveToken(
          token.target, attacker.address, TRANSFER_AMOUNT
        )
      ).to.be.reverted;
    });

    it("should reject execute from non-governance", async function () {
      await expect(
        treasury.connect(attacker).execute(token.target, 0, "0x")
      ).to.be.reverted;
    });

    it("should reject executeBatch from non-governance", async function () {
      await expect(
        treasury.connect(attacker).executeBatch(
          [token.target], [0], ["0x"]
        )
      ).to.be.reverted;
    });

    it("should reject transferNFT from non-governance", async function () {
      await nft.mint(treasury.target, 1);
      await expect(
        treasury.connect(attacker).transferNFT(
          nft.target, attacker.address, 1
        )
      ).to.be.reverted;
    });

    it("should reject transferERC1155 from non-governance", async function () {
      await erc1155.mint(treasury.target, 1, 100);
      await expect(
        treasury.connect(attacker).transferERC1155(
          erc1155.target, attacker.address, 1, 100, "0x"
        )
      ).to.be.reverted;
    });

    it("should reject pause from non-guardian", async function () {
      await expect(
        treasury.connect(attacker).pause()
      ).to.be.reverted;
    });

    it("should reject unpause from non-admin", async function () {
      await treasury.connect(guardian).pause();
      await expect(
        treasury.connect(attacker).unpause()
      ).to.be.reverted;
    });

    it("should reject unpause from guardian (requires admin)", async function () {
      await treasury.connect(guardian).pause();
      await expect(
        treasury.connect(guardian).unpause()
      ).to.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  10. Pause / Unpause
  // ═══════════════════════════════════════════════════════════════════

  describe("Pause / Unpause", function () {
    beforeEach(async function () {
      await token.mint(treasury.target, MINT_AMOUNT);
      await admin.sendTransaction({
        to: treasury.target,
        value: ethers.parseEther("10"),
      });
    });

    it("should allow guardian to pause", async function () {
      await treasury.connect(guardian).pause();
      expect(await treasury.paused()).to.be.true;
    });

    it("should allow admin to unpause", async function () {
      await treasury.connect(guardian).pause();
      await treasury.connect(admin).unpause();
      expect(await treasury.paused()).to.be.false;
    });

    it("should block transferToken when paused", async function () {
      await treasury.connect(guardian).pause();
      await expect(
        treasury.connect(governance).transferToken(
          token.target, recipient.address, TRANSFER_AMOUNT
        )
      ).to.be.revertedWithCustomError(treasury, "EnforcedPause");
    });

    it("should block transferNative when paused", async function () {
      await treasury.connect(guardian).pause();
      await expect(
        treasury.connect(governance).transferNative(recipient.address, ONE_XOM)
      ).to.be.revertedWithCustomError(treasury, "EnforcedPause");
    });

    it("should block approveToken when paused", async function () {
      await treasury.connect(guardian).pause();
      await expect(
        treasury.connect(governance).approveToken(
          token.target, recipient.address, TRANSFER_AMOUNT
        )
      ).to.be.revertedWithCustomError(treasury, "EnforcedPause");
    });

    it("should block execute when paused", async function () {
      await treasury.connect(guardian).pause();
      await expect(
        treasury.connect(governance).execute(token.target, 0, "0x")
      ).to.be.revertedWithCustomError(treasury, "EnforcedPause");
    });

    it("should block executeBatch when paused", async function () {
      await treasury.connect(guardian).pause();
      await expect(
        treasury.connect(governance).executeBatch(
          [token.target], [0], ["0x"]
        )
      ).to.be.revertedWithCustomError(treasury, "EnforcedPause");
    });

    it("should still accept native XOM when paused", async function () {
      await treasury.connect(guardian).pause();
      // receive() is not gated by whenNotPaused
      await expect(
        admin.sendTransaction({ to: treasury.target, value: ONE_XOM })
      ).to.emit(treasury, "NativeReceived");
    });

    it("should resume after unpause", async function () {
      await treasury.connect(guardian).pause();
      await treasury.connect(admin).unpause();

      // Should work again after unpause
      await expect(
        treasury.connect(governance).transferToken(
          token.target, recipient.address, TRANSFER_AMOUNT
        )
      ).to.emit(treasury, "TokenTransferred");
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  11. Reentrancy Protection
  // ═══════════════════════════════════════════════════════════════════

  describe("Reentrancy Protection", function () {
    it("should prevent reentrancy on transferNative", async function () {
      // Deploy a ReentrantReceiver that tries to re-enter transferNative
      const ReentrantReceiver = await ethers.getContractFactory(
        "ReentrantReceiver"
      );
      const malicious = await ReentrantReceiver.deploy(treasury.target);
      await malicious.waitForDeployment();

      // Fund treasury
      await admin.sendTransaction({
        to: treasury.target,
        value: ethers.parseEther("10"),
      });

      // Grant GOVERNANCE_ROLE to admin (already has it)
      // Try to send native XOM to the malicious contract
      await expect(
        treasury.connect(admin).transferNative(
          malicious.target, ONE_XOM
        )
      ).to.be.revertedWithCustomError(treasury, "NativeTransferFailed");
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  12. supportsInterface (ERC-165)
  // ═══════════════════════════════════════════════════════════════════

  describe("supportsInterface", function () {
    it("should support AccessControl interface", async function () {
      // IAccessControl: 0x7965db0b
      expect(await treasury.supportsInterface("0x7965db0b")).to.be.true;
    });

    it("should support ERC-721 Receiver interface", async function () {
      // IERC721Receiver: 0x150b7a02
      expect(await treasury.supportsInterface("0x150b7a02")).to.be.true;
    });

    it("should support ERC-1155 Receiver interface", async function () {
      // IERC1155Receiver: 0x4e2312e0
      expect(await treasury.supportsInterface("0x4e2312e0")).to.be.true;
    });

    it("should support ERC-165 itself", async function () {
      // IERC165: 0x01ffc9a7
      expect(await treasury.supportsInterface("0x01ffc9a7")).to.be.true;
    });

    it("should NOT support random interface", async function () {
      expect(await treasury.supportsInterface("0xffffffff")).to.be.false;
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  View Functions
  // ═══════════════════════════════════════════════════════════════════

  describe("View Functions", function () {
    it("should return correct tokenBalance", async function () {
      await token.mint(treasury.target, MINT_AMOUNT);
      expect(await treasury.tokenBalance(token.target)).to.equal(MINT_AMOUNT);
    });

    it("should return zero tokenBalance for unfunded token", async function () {
      expect(await treasury.tokenBalance(token.target)).to.equal(0);
    });

    it("should return correct nativeBalance", async function () {
      await admin.sendTransaction({
        to: treasury.target,
        value: ethers.parseEther("5"),
      });
      expect(await treasury.nativeBalance()).to.equal(ethers.parseEther("5"));
    });

    it("should return zero nativeBalance initially", async function () {
      expect(await treasury.nativeBalance()).to.equal(0);
    });
  });
});
