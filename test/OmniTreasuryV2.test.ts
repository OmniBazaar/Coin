/* eslint-disable @typescript-eslint/no-require-imports, @typescript-eslint/no-var-requires */
/* eslint-disable @typescript-eslint/no-explicit-any */
const { expect } = require("chai");
const { ethers } = require("hardhat");

type Signer = any;

/**
 * @title OmniTreasuryV2 Test Suite
 * @notice Functional + security coverage for the POL treasury redeploy
 *         target (GATE 1, pre-mainnet).
 * @dev Covers: constructor / role setup, every role gate, the POL
 *      surface (transferTokenToPOL / approveTokenForPOL / setPOLTarget),
 *      M-03 (POL_DEPLOYER_ROLE must be a contract), M-08 (bounded
 *      _activeApprovals), M-03/L-01 (transitionGovernance robustness),
 *      ERC721/1155 receipt, pause gating, and native receive().
 */
describe("OmniTreasuryV2", function () {
  let treasury: any;
  let token: any;
  let nft: any;
  let erc1155: any;
  let admin: Signer;
  let governance: Signer;
  let guardian: Signer;
  let polManager: any; // a contract that can hold POL_DEPLOYER_ROLE
  let recipient: Signer;
  let attacker: Signer;
  let adminAddr: string;
  let govAddr: string;
  let guardianAddr: string;
  let recipientAddr: string;
  let attackerAddr: string;

  let DEFAULT_ADMIN_ROLE: string;
  let GOVERNANCE_ROLE: string;
  let GUARDIAN_ROLE: string;
  let POL_DEPLOYER_ROLE: string;

  const MINT = ethers.parseEther("1000000");
  const ONE = ethers.parseEther("1");

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    admin = signers[0];
    governance = signers[1];
    guardian = signers[2];
    recipient = signers[3];
    attacker = signers[4];
    adminAddr = await admin.getAddress();
    govAddr = await governance.getAddress();
    guardianAddr = await guardian.getAddress();
    recipientAddr = await recipient.getAddress();
    attackerAddr = await attacker.getAddress();

    const Treasury = await ethers.getContractFactory("OmniTreasuryV2");
    treasury = await Treasury.deploy(adminAddr);
    await treasury.waitForDeployment();

    DEFAULT_ADMIN_ROLE = await treasury.DEFAULT_ADMIN_ROLE();
    GOVERNANCE_ROLE = await treasury.GOVERNANCE_ROLE();
    GUARDIAN_ROLE = await treasury.GUARDIAN_ROLE();
    POL_DEPLOYER_ROLE = await treasury.POL_DEPLOYER_ROLE();

    await treasury.connect(admin).grantRole(GOVERNANCE_ROLE, govAddr);
    await treasury.connect(admin).grantRole(GUARDIAN_ROLE, guardianAddr);

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    token = await MockERC20.deploy("OmniCoin", "XOM");
    await token.waitForDeployment();
    await token.mint(treasury.target, MINT);

    const MockERC721 = await ethers.getContractFactory("MockERC721");
    nft = await MockERC721.deploy("OmniNFT", "ONFT");
    await nft.waitForDeployment();

    const MockERC1155 = await ethers.getContractFactory("MockERC1155");
    erc1155 = await MockERC1155.deploy();
    await erc1155.waitForDeployment();

    // A real contract to act as POLManager / a whitelisted POL target.
    // MockERC20 is a deployed contract, so it satisfies the M-03
    // contract-only invariant for POL_DEPLOYER_ROLE.
    const PolMock = await ethers.getContractFactory("MockERC20");
    polManager = await PolMock.deploy("PolTarget", "POLT");
    await polManager.waitForDeployment();
  });

  // ════════════════════════════════════════════════════════════════
  //  1. Constructor / Role Setup
  // ════════════════════════════════════════════════════════════════

  describe("Constructor / role setup", function () {
    it("grants admin, governance, guardian roles to the admin", async function () {
      expect(await treasury.hasRole(DEFAULT_ADMIN_ROLE, adminAddr)).to.be
        .true;
      expect(await treasury.hasRole(GOVERNANCE_ROLE, adminAddr)).to.be.true;
      expect(await treasury.hasRole(GUARDIAN_ROLE, adminAddr)).to.be.true;
    });

    it("does NOT grant POL_DEPLOYER_ROLE in the constructor", async function () {
      expect(await treasury.hasRole(POL_DEPLOYER_ROLE, adminAddr)).to.be
        .false;
    });

    it("reverts deployment with the zero address", async function () {
      const Treasury = await ethers.getContractFactory("OmniTreasuryV2");
      await expect(
        Treasury.deploy(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(treasury, "ZeroAddress");
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  2. Native receive()
  // ════════════════════════════════════════════════════════════════

  describe("Native reception", function () {
    it("accepts native XOM and emits NativeReceived", async function () {
      await expect(
        admin.sendTransaction({ to: treasury.target, value: ONE })
      )
        .to.emit(treasury, "NativeReceived")
        .withArgs(adminAddr, ONE);
      expect(await treasury.nativeBalance()).to.equal(ONE);
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  3. Role gates — governance functions
  // ════════════════════════════════════════════════════════════════

  describe("GOVERNANCE_ROLE gate", function () {
    it("transferToken requires GOVERNANCE_ROLE", async function () {
      await expect(
        treasury
          .connect(attacker)
          .transferToken(token.target, recipientAddr, ONE)
      ).to.be.revertedWithCustomError(
        treasury,
        "AccessControlUnauthorizedAccount"
      );
      await expect(
        treasury
          .connect(governance)
          .transferToken(token.target, recipientAddr, ONE)
      )
        .to.emit(treasury, "TokenTransferred")
        .withArgs(token.target, recipientAddr, ONE);
      expect(await token.balanceOf(recipientAddr)).to.equal(ONE);
    });

    it("transferNative requires GOVERNANCE_ROLE", async function () {
      await admin.sendTransaction({ to: treasury.target, value: ONE });
      await expect(
        treasury.connect(attacker).transferNative(recipientAddr, ONE)
      ).to.be.revertedWithCustomError(
        treasury,
        "AccessControlUnauthorizedAccount"
      );
      await expect(
        treasury.connect(governance).transferNative(recipientAddr, ONE)
      ).to.emit(treasury, "NativeTransferred");
    });

    it("approveToken requires GOVERNANCE_ROLE", async function () {
      await expect(
        treasury
          .connect(attacker)
          .approveToken(token.target, recipientAddr, ONE)
      ).to.be.revertedWithCustomError(
        treasury,
        "AccessControlUnauthorizedAccount"
      );
      await treasury
        .connect(governance)
        .approveToken(token.target, recipientAddr, ONE);
      expect(
        await token.allowance(treasury.target, recipientAddr)
      ).to.equal(ONE);
    });

    it("transferNFT requires GOVERNANCE_ROLE", async function () {
      await nft.mint(treasury.target, 1);
      await expect(
        treasury.connect(attacker).transferNFT(nft.target, recipientAddr, 1)
      ).to.be.revertedWithCustomError(
        treasury,
        "AccessControlUnauthorizedAccount"
      );
      await treasury
        .connect(governance)
        .transferNFT(nft.target, recipientAddr, 1);
      expect(await nft.ownerOf(1)).to.equal(recipientAddr);
    });

    it("transferERC1155 requires GOVERNANCE_ROLE", async function () {
      await erc1155.mint(treasury.target, 7, 100);
      await expect(
        treasury
          .connect(attacker)
          .transferERC1155(erc1155.target, recipientAddr, 7, 50, "0x")
      ).to.be.revertedWithCustomError(
        treasury,
        "AccessControlUnauthorizedAccount"
      );
      await treasury
        .connect(governance)
        .transferERC1155(erc1155.target, recipientAddr, 7, 50, "0x");
      expect(await erc1155.balanceOf(recipientAddr, 7)).to.equal(50);
    });

    it("execute requires GOVERNANCE_ROLE", async function () {
      const calldata = token.interface.encodeFunctionData("mint", [
        recipientAddr,
        ONE,
      ]);
      await expect(
        treasury.connect(attacker).execute(token.target, 0, calldata)
      ).to.be.revertedWithCustomError(
        treasury,
        "AccessControlUnauthorizedAccount"
      );
      await treasury
        .connect(governance)
        .execute(token.target, 0, calldata);
      expect(await token.balanceOf(recipientAddr)).to.equal(ONE);
    });

    it("execute rejects a self-call", async function () {
      await expect(
        treasury.connect(governance).execute(treasury.target, 0, "0x")
      ).to.be.revertedWithCustomError(treasury, "SelfCallNotAllowed");
    });

    it("executeBatch requires GOVERNANCE_ROLE and runs the batch", async function () {
      const cd = token.interface.encodeFunctionData("mint", [
        recipientAddr,
        ONE,
      ]);
      await expect(
        treasury
          .connect(attacker)
          .executeBatch([token.target], [0], [cd])
      ).to.be.revertedWithCustomError(
        treasury,
        "AccessControlUnauthorizedAccount"
      );
      await expect(
        treasury
          .connect(governance)
          .executeBatch([token.target, token.target], [0, 0], [cd, cd])
      )
        .to.emit(treasury, "BatchExecuted")
        .withArgs(2);
      expect(await token.balanceOf(recipientAddr)).to.equal(ONE * 2n);
    });

    it("executeBatch reverts on array length mismatch", async function () {
      await expect(
        treasury
          .connect(governance)
          .executeBatch([token.target], [0, 0], ["0x"])
      ).to.be.revertedWithCustomError(treasury, "ArrayLengthMismatch");
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  4. Role gates — guardian / admin
  // ════════════════════════════════════════════════════════════════

  describe("GUARDIAN / ADMIN gates", function () {
    it("pause requires GUARDIAN_ROLE", async function () {
      await expect(
        treasury.connect(attacker).pause()
      ).to.be.revertedWithCustomError(
        treasury,
        "AccessControlUnauthorizedAccount"
      );
      await treasury.connect(guardian).pause();
      expect(await treasury.paused()).to.be.true;
    });

    it("unpause requires DEFAULT_ADMIN_ROLE (not guardian)", async function () {
      await treasury.connect(guardian).pause();
      await expect(
        treasury.connect(guardian).unpause()
      ).to.be.revertedWithCustomError(
        treasury,
        "AccessControlUnauthorizedAccount"
      );
      await treasury.connect(admin).unpause();
      expect(await treasury.paused()).to.be.false;
    });

    it("setPOLTarget requires DEFAULT_ADMIN_ROLE (not governance)", async function () {
      await expect(
        treasury
          .connect(governance)
          .setPOLTarget(polManager.target, true)
      ).to.be.revertedWithCustomError(
        treasury,
        "AccessControlUnauthorizedAccount"
      );
      await expect(
        treasury.connect(admin).setPOLTarget(polManager.target, true)
      )
        .to.emit(treasury, "POLTargetSet")
        .withArgs(polManager.target, true);
      expect(await treasury.isPOLTarget(polManager.target)).to.be.true;
    });

    it("setPOLTarget rejects the treasury itself and zero address", async function () {
      await expect(
        treasury.connect(admin).setPOLTarget(treasury.target, true)
      ).to.be.revertedWithCustomError(
        treasury,
        "InvalidGovernanceTarget"
      );
      await expect(
        treasury.connect(admin).setPOLTarget(ethers.ZeroAddress, true)
      ).to.be.revertedWithCustomError(treasury, "ZeroAddress");
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  5. POL surface — transferTokenToPOL / approveTokenForPOL
  // ════════════════════════════════════════════════════════════════

  describe("POL surface", function () {
    beforeEach(async function () {
      // Grant POL_DEPLOYER_ROLE to the polManager contract and
      // whitelist it as a POL target.
      await treasury
        .connect(admin)
        .grantRole(POL_DEPLOYER_ROLE, polManager.target);
      await treasury
        .connect(admin)
        .setPOLTarget(polManager.target, true);
    });

    it("transferTokenToPOL requires POL_DEPLOYER_ROLE", async function () {
      // Even GOVERNANCE_ROLE cannot call the POL-scoped function.
      await expect(
        treasury
          .connect(governance)
          .transferTokenToPOL(token.target, polManager.target, ONE)
      ).to.be.revertedWithCustomError(
        treasury,
        "AccessControlUnauthorizedAccount"
      );
    });

    it("transferTokenToPOL succeeds only to a whitelisted target", async function () {
      // The polManager contract is the role holder; impersonate it.
      await ethers.provider.send("hardhat_setBalance", [
        polManager.target,
        "0xDE0B6B3A7640000",
      ]);
      const polSigner = await ethers.getImpersonatedSigner(
        polManager.target
      );
      // Whitelisted target → success.
      await expect(
        treasury
          .connect(polSigner)
          .transferTokenToPOL(token.target, polManager.target, ONE)
      )
        .to.emit(treasury, "POLTokenTransferred")
        .withArgs(token.target, polManager.target, ONE);
      expect(await token.balanceOf(polManager.target)).to.equal(ONE);
    });

    it("transferTokenToPOL reverts on a non-whitelisted target", async function () {
      await ethers.provider.send("hardhat_setBalance", [
        polManager.target,
        "0xDE0B6B3A7640000",
      ]);
      const polSigner = await ethers.getImpersonatedSigner(
        polManager.target
      );
      await expect(
        treasury
          .connect(polSigner)
          .transferTokenToPOL(token.target, recipientAddr, ONE)
      )
        .to.be.revertedWithCustomError(treasury, "POLTargetNotAllowed")
        .withArgs(recipientAddr);
    });

    it("transferTokenToPOL reverts when target == address(this)", async function () {
      await ethers.provider.send("hardhat_setBalance", [
        polManager.target,
        "0xDE0B6B3A7640000",
      ]);
      const polSigner = await ethers.getImpersonatedSigner(
        polManager.target
      );
      await expect(
        treasury
          .connect(polSigner)
          .transferTokenToPOL(token.target, treasury.target, ONE)
      ).to.be.revertedWithCustomError(treasury, "SelfCallNotAllowed");
    });

    it("approveTokenForPOL succeeds to whitelisted, reverts otherwise", async function () {
      await ethers.provider.send("hardhat_setBalance", [
        polManager.target,
        "0xDE0B6B3A7640000",
      ]);
      const polSigner = await ethers.getImpersonatedSigner(
        polManager.target
      );
      await expect(
        treasury
          .connect(polSigner)
          .approveTokenForPOL(token.target, polManager.target, ONE)
      )
        .to.emit(treasury, "POLTokenApproved")
        .withArgs(token.target, polManager.target, ONE);
      expect(
        await token.allowance(treasury.target, polManager.target)
      ).to.equal(ONE);
      await expect(
        treasury
          .connect(polSigner)
          .approveTokenForPOL(token.target, recipientAddr, ONE)
      ).to.be.revertedWithCustomError(treasury, "POLTargetNotAllowed");
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  6. M-03 — POL_DEPLOYER_ROLE must be a contract
  // ════════════════════════════════════════════════════════════════

  describe("M-03: POL_DEPLOYER_ROLE contract-only invariant", function () {
    it("reverts granting POL_DEPLOYER_ROLE to an EOA", async function () {
      await expect(
        treasury
          .connect(admin)
          .grantRole(POL_DEPLOYER_ROLE, attackerAddr)
      )
        .to.be.revertedWithCustomError(
          treasury,
          "POLDeployerMustBeContract"
        )
        .withArgs(attackerAddr);
    });

    it("succeeds granting POL_DEPLOYER_ROLE to a contract", async function () {
      await treasury
        .connect(admin)
        .grantRole(POL_DEPLOYER_ROLE, polManager.target);
      expect(
        await treasury.hasRole(POL_DEPLOYER_ROLE, polManager.target)
      ).to.be.true;
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  7. M-08 — bounded _activeApprovals
  // ════════════════════════════════════════════════════════════════

  describe("M-08: bounded active-approval array", function () {
    it("tracks non-zero approvals and revokeAllApprovals clears them", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const t1 = await MockERC20.deploy("T1", "T1");
      const t2 = await MockERC20.deploy("T2", "T2");
      await treasury
        .connect(governance)
        .approveToken(t1.target, recipientAddr, ONE);
      await treasury
        .connect(governance)
        .approveToken(t2.target, attackerAddr, ONE);
      expect(await treasury.activeApprovalCount()).to.equal(2);
      await expect(treasury.connect(governance).revokeAllApprovals())
        .to.emit(treasury, "AllApprovalsRevoked")
        .withArgs(2);
      expect(await treasury.activeApprovalCount()).to.equal(0);
      expect(
        await t1.allowance(treasury.target, recipientAddr)
      ).to.equal(0);
    });

    it("enforces the MAX_ACTIVE_APPROVALS cap (256)", async function () {
      const cap = Number(await treasury.MAX_ACTIVE_APPROVALS());
      expect(cap).to.equal(256);
      // Fill toward the cap. S-02 dedupe means the same (token, spender)
      // pair is tracked once, so 256 DISTINCT spenders fill the array.
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const t = await MockERC20.deploy("Fill", "FILL");
      // One token + `cap` distinct spenders fills the array to the cap.
      for (let i = 0; i < cap; i++) {
        const spender = ethers.Wallet.createRandom().address;
        await treasury
          .connect(governance)
          .approveToken(t.target, spender, ONE);
      }
      expect(await treasury.activeApprovalCount()).to.equal(cap);
      // The 257th non-zero approval (a new spender) must revert.
      await expect(
        treasury
          .connect(governance)
          .approveToken(t.target, ethers.Wallet.createRandom().address, ONE)
      ).to.be.revertedWithCustomError(
        treasury,
        "TooManyActiveApprovals"
      );
      // A zero-amount approval is NOT tracked, so it still works.
      await treasury
        .connect(governance)
        .approveToken(t.target, ethers.Wallet.createRandom().address, 0);
      // revokeAllApprovals is the relief valve.
      await treasury.connect(governance).revokeAllApprovals();
      expect(await treasury.activeApprovalCount()).to.equal(0);
    });

    it("deduplicates repeated approvals of the same (token, spender)", async function () {
      await treasury
        .connect(governance)
        .approveToken(token.target, recipientAddr, ONE);
      // Same pair approved again (non-zero) must NOT add a second entry.
      await treasury
        .connect(governance)
        .approveToken(token.target, recipientAddr, ONE);
      expect(await treasury.activeApprovalCount()).to.equal(1);
    });

    it("removes a tracked approval when the amount is zeroed", async function () {
      await treasury
        .connect(governance)
        .approveToken(token.target, recipientAddr, ONE);
      expect(await treasury.activeApprovalCount()).to.equal(1);
      // Zeroing the approval removes it from active tracking (S-03).
      await treasury
        .connect(governance)
        .approveToken(token.target, recipientAddr, 0);
      expect(await treasury.activeApprovalCount()).to.equal(0);
      expect(
        await token.allowance(treasury.target, recipientAddr)
      ).to.equal(0);
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  8. M-03 / L-01 — transitionGovernance robustness
  // ════════════════════════════════════════════════════════════════

  describe("transitionGovernance", function () {
    it("does NOT brick on a token whose approve() reverts", async function () {
      // Set up an active approval with a malicious token.
      const Bad = await ethers.getContractFactory(
        "MockRevertingApproveToken"
      );
      const bad = await Bad.deploy("Bad", "BAD");
      await bad.mint(treasury.target, MINT);
      // Approve while well-behaved so the approval is tracked.
      await treasury
        .connect(governance)
        .approveToken(bad.target, recipientAddr, ONE);
      expect(await treasury.activeApprovalCount()).to.equal(1);
      // Now sabotage the token so approve(0) reverts.
      await bad.setRevertOnApprove(true);

      // transitionGovernance must still succeed — the try/catch in
      // _revokeAllApprovalsInternal absorbs the revert and emits
      // ApprovalRevocationFailed.
      await expect(
        treasury
          .connect(admin)
          .transitionGovernance(govAddr, guardianAddr, recipientAddr)
      )
        .to.emit(treasury, "ApprovalRevocationFailed")
        .withArgs(bad.target, recipientAddr)
        .and.to.emit(treasury, "GovernanceTransitioned")
        .withArgs(govAddr, guardianAddr, recipientAddr);

      // Roles transitioned: admin no longer admin, new holders set.
      expect(await treasury.hasRole(DEFAULT_ADMIN_ROLE, adminAddr)).to.be
        .false;
      expect(
        await treasury.hasRole(DEFAULT_ADMIN_ROLE, recipientAddr)
      ).to.be.true;
    });

    it("rejects a self-transition (CannotTransitionToSelf)", async function () {
      await expect(
        treasury
          .connect(admin)
          .transitionGovernance(adminAddr, guardianAddr, recipientAddr)
      ).to.be.revertedWithCustomError(
        treasury,
        "CannotTransitionToSelf"
      );
    });

    it("rejects duplicate role targets", async function () {
      await expect(
        treasury
          .connect(admin)
          .transitionGovernance(govAddr, govAddr, recipientAddr)
      ).to.be.revertedWithCustomError(
        treasury,
        "DuplicateGovernanceTarget"
      );
    });

    it("rejects zero-address targets", async function () {
      await expect(
        treasury
          .connect(admin)
          .transitionGovernance(
            ethers.ZeroAddress,
            guardianAddr,
            recipientAddr
          )
      ).to.be.revertedWithCustomError(treasury, "ZeroAddress");
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  9. ERC721 / ERC1155 receipt + interface support
  // ════════════════════════════════════════════════════════════════

  describe("Asset receipt + interfaces", function () {
    it("receives ERC-721 via safeTransferFrom", async function () {
      await nft.mint(adminAddr, 42);
      await nft
        .connect(admin)
        ["safeTransferFrom(address,address,uint256)"](
          adminAddr,
          treasury.target,
          42
        );
      expect(await nft.ownerOf(42)).to.equal(treasury.target);
    });

    it("receives ERC-1155 via safeTransferFrom", async function () {
      await erc1155.mint(adminAddr, 3, 500);
      await erc1155
        .connect(admin)
        .safeTransferFrom(adminAddr, treasury.target, 3, 200, "0x");
      expect(await erc1155.balanceOf(treasury.target, 3)).to.equal(200);
    });

    it("reports supportsInterface for AccessControl + receivers", async function () {
      // IERC165
      expect(await treasury.supportsInterface("0x01ffc9a7")).to.be.true;
      // IERC721Receiver
      expect(await treasury.supportsInterface("0x150b7a02")).to.be.true;
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  10. Pause blocks transfers
  // ════════════════════════════════════════════════════════════════

  describe("Pause gating", function () {
    it("blocks transferToken while paused", async function () {
      await treasury.connect(guardian).pause();
      await expect(
        treasury
          .connect(governance)
          .transferToken(token.target, recipientAddr, ONE)
      ).to.be.revertedWithCustomError(treasury, "EnforcedPause");
    });

    it("blocks POL transfers while paused", async function () {
      await treasury
        .connect(admin)
        .grantRole(POL_DEPLOYER_ROLE, polManager.target);
      await treasury
        .connect(admin)
        .setPOLTarget(polManager.target, true);
      await treasury.connect(guardian).pause();
      await ethers.provider.send("hardhat_setBalance", [
        polManager.target,
        "0xDE0B6B3A7640000",
      ]);
      const polSigner = await ethers.getImpersonatedSigner(
        polManager.target
      );
      await expect(
        treasury
          .connect(polSigner)
          .transferTokenToPOL(token.target, polManager.target, ONE)
      ).to.be.revertedWithCustomError(treasury, "EnforcedPause");
    });

    it("resumes transfers after unpause", async function () {
      await treasury.connect(guardian).pause();
      await treasury.connect(admin).unpause();
      await treasury
        .connect(governance)
        .transferToken(token.target, recipientAddr, ONE);
      expect(await token.balanceOf(recipientAddr)).to.equal(ONE);
    });
  });

  // ════════════════════════════════════════════════════════════════
  //  11. Zero-amount / zero-address guards
  // ════════════════════════════════════════════════════════════════

  describe("Input guards", function () {
    it("transferToken reverts on zero amount and zero recipient", async function () {
      await expect(
        treasury
          .connect(governance)
          .transferToken(token.target, recipientAddr, 0)
      ).to.be.revertedWithCustomError(treasury, "ZeroAmount");
      await expect(
        treasury
          .connect(governance)
          .transferToken(token.target, ethers.ZeroAddress, ONE)
      ).to.be.revertedWithCustomError(treasury, "ZeroAddress");
    });
  });
});
