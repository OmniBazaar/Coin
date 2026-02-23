const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time, mine } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * Comprehensive test suite for the UUPS Upgradeability & Governance system.
 *
 * Tests cover:
 * 1. OmniCoin ERC20Votes (delegation, getPastVotes, nonces)
 * 2. OmniTimelockController (two-tier delays, critical selectors)
 * 3. EmergencyGuardian (pause 1-of-N, cancel 3-of-5, guardian management)
 * 4. OmniGovernance (propose, vote, queue, execute, cancel, ossify)
 * 5. OmniCore staking snapshots (getStakedAt)
 * 6. OmniBridge UUPS (initialize, ossify)
 * 7. Ossification pattern (across UUPS contracts)
 */
describe("UUPS Governance System", function () {
  let token, core, timelock, guardian, governance;
  let owner, admin, proposer, voter1, voter2, voter3;
  let guardian1, guardian2, guardian3, guardian4, guardian5;

  const ROUTINE_DELAY = 48 * 60 * 60; // 48 hours
  const CRITICAL_DELAY = 7 * 24 * 60 * 60; // 7 days
  const VOTING_DELAY = 1 * 24 * 60 * 60; // 1 day
  const VOTING_PERIOD = 5 * 24 * 60 * 60; // 5 days
  const PROPOSAL_THRESHOLD = ethers.parseEther("10000");
  const QUORUM_BPS = 400;
  const BASIS_POINTS = 10000;

  /**
   * Helper: deploy OmniCoin, OmniCore, OmniTimelockController,
   * EmergencyGuardian, and OmniGovernance in the correct order.
   */
  async function deployFullStack() {
    [
      owner, admin, proposer, voter1, voter2, voter3,
      guardian1, guardian2, guardian3, guardian4, guardian5
    ] = await ethers.getSigners();

    // 1. Deploy OmniCoin
    const Token = await ethers.getContractFactory("OmniCoin");
    token = await Token.deploy();
    await token.initialize();

    // 2. Deploy OmniCore via UUPS proxy
    const OmniCore = await ethers.getContractFactory("OmniCore");
    core = await upgrades.deployProxy(
      OmniCore,
      [admin.address, token.target, admin.address, admin.address],
      { initializer: "initialize" }
    );

    // Register OmniCoin service
    await core.connect(admin).setService(ethers.id("OMNICOIN"), token.target);

    // Grant MINTER_ROLE so staking works
    await token.grantRole(await token.MINTER_ROLE(), core.target);

    // 3. Deploy OmniTimelockController
    const guardianAddresses = [
      guardian1.address, guardian2.address, guardian3.address,
      guardian4.address, guardian5.address
    ];

    // Timelock: proposers=[owner], executors=[zero address = anyone], admin=owner
    const Timelock = await ethers.getContractFactory("OmniTimelockController");
    timelock = await Timelock.deploy(
      [owner.address], // proposers (will add governance later)
      [ethers.ZeroAddress], // executors (anyone)
      owner.address // admin
    );

    // 4. Deploy EmergencyGuardian
    const Guardian = await ethers.getContractFactory("EmergencyGuardian");
    guardian = await Guardian.deploy(timelock.target, guardianAddresses);

    // Grant CANCELLER_ROLE to EmergencyGuardian
    const CANCELLER_ROLE = await timelock.CANCELLER_ROLE();
    await timelock.connect(owner).grantRole(CANCELLER_ROLE, guardian.target);

    // 5. Deploy OmniGovernance via UUPS proxy
    const Governance = await ethers.getContractFactory("OmniGovernance");
    governance = await upgrades.deployProxy(
      Governance,
      [token.target, core.target, timelock.target, admin.address],
      { initializer: "initialize", kind: "uups" }
    );

    // Grant PROPOSER_ROLE to governance
    const PROPOSER_ROLE = await timelock.PROPOSER_ROLE();
    await timelock.connect(owner).grantRole(PROPOSER_ROLE, governance.target);

    // Distribute tokens for voting
    await token.mint(proposer.address, ethers.parseEther("15000"));
    await token.mint(voter1.address, ethers.parseEther("50000"));
    await token.mint(voter2.address, ethers.parseEther("40000"));
    await token.mint(voter3.address, ethers.parseEther("30000"));

    // Delegate to self so ERC20Votes checkpoints are active
    await token.connect(proposer).delegate(proposer.address);
    await token.connect(voter1).delegate(voter1.address);
    await token.connect(voter2).delegate(voter2.address);
    await token.connect(voter3).delegate(voter3.address);
    await token.connect(owner).delegate(owner.address);
  }

  // =========================================================================
  // 1. OmniCoin ERC20Votes
  // =========================================================================
  describe("OmniCoin ERC20Votes", function () {
    beforeEach(deployFullStack);

    it("Should support self-delegation for voting power", async function () {
      const votes = await token.getVotes(voter1.address);
      expect(votes).to.equal(ethers.parseEther("50000"));
    });

    it("Should allow delegating to another address", async function () {
      await token.connect(voter2).delegate(voter1.address);

      const voter1Votes = await token.getVotes(voter1.address);
      const voter2Votes = await token.getVotes(voter2.address);

      // voter1 has own 50k + voter2's 40k = 90k
      expect(voter1Votes).to.equal(ethers.parseEther("90000"));
      expect(voter2Votes).to.equal(0);
    });

    it("Should track past votes via checkpoints", async function () {
      const blockBefore = await ethers.provider.getBlockNumber();

      // Mine a block to make sure the checkpoint is in the past
      await mine(1);

      const pastVotes = await token.getPastVotes(
        voter1.address, blockBefore
      );
      expect(pastVotes).to.equal(ethers.parseEther("50000"));
    });

    it("Should update checkpoints on transfer", async function () {
      const blockBefore = await ethers.provider.getBlockNumber();

      // Transfer 10k from voter1 to voter2
      await token.connect(voter1).transfer(
        voter2.address, ethers.parseEther("10000")
      );

      await mine(1);
      const blockAfter = await ethers.provider.getBlockNumber();

      // Past votes at blockBefore should reflect pre-transfer state
      const pastVotes1 = await token.getPastVotes(
        voter1.address, blockBefore
      );
      expect(pastVotes1).to.equal(ethers.parseEther("50000"));

      // Current votes should reflect post-transfer state
      const currentVotes1 = await token.getVotes(voter1.address);
      expect(currentVotes1).to.equal(ethers.parseEther("40000"));
    });

    it("Should support ERC20Permit for gasless approvals", async function () {
      // OmniCoin inherits ERC20Permit - verify nonces exist
      const nonce = await token.nonces(voter1.address);
      expect(nonce).to.equal(0);
    });
  });

  // =========================================================================
  // 2. OmniTimelockController
  // =========================================================================
  describe("OmniTimelockController", function () {
    beforeEach(deployFullStack);

    it("Should have correct routine and critical delays", async function () {
      expect(await timelock.ROUTINE_DELAY()).to.equal(ROUTINE_DELAY);
      expect(await timelock.CRITICAL_DELAY()).to.equal(CRITICAL_DELAY);
    });

    it("Should have minimum delay set to ROUTINE_DELAY", async function () {
      const minDelay = await timelock.getMinDelay();
      expect(minDelay).to.equal(ROUTINE_DELAY);
    });

    it("Should classify upgrade selectors as critical", async function () {
      const upgradeToSel = "0x3659cfe6";
      const upgradeToAndCallSel = "0x4f1ef286";

      expect(await timelock.isCriticalSelector(upgradeToSel)).to.be.true;
      expect(await timelock.isCriticalSelector(upgradeToAndCallSel)).to.be.true;
    });

    it("Should classify role management selectors as critical", async function () {
      const grantRoleSel = "0x2f2ff15d";
      const revokeRoleSel = "0xd547741f";
      const renounceRoleSel = "0x36568abe";

      expect(await timelock.isCriticalSelector(grantRoleSel)).to.be.true;
      expect(await timelock.isCriticalSelector(revokeRoleSel)).to.be.true;
      expect(await timelock.isCriticalSelector(renounceRoleSel)).to.be.true;
    });

    it("Should classify pause/unpause as critical", async function () {
      const pauseSel = "0x8456cb59";
      const unpauseSel = "0x3f4ba83a";

      expect(await timelock.isCriticalSelector(pauseSel)).to.be.true;
      expect(await timelock.isCriticalSelector(unpauseSel)).to.be.true;
    });

    it("Should report 7 initial critical selectors", async function () {
      expect(await timelock.criticalSelectorCount()).to.equal(7);
    });

    it("Should return ROUTINE_DELAY for non-critical calldata", async function () {
      // Random non-critical function selector
      const routineCalldata = ethers.solidityPacked(
        ["bytes4", "uint256"],
        ["0xdeadbeef", 42]
      );
      const delay = await timelock.getRequiredDelay(routineCalldata);
      expect(delay).to.equal(ROUTINE_DELAY);
    });

    it("Should return CRITICAL_DELAY for critical calldata", async function () {
      // grantRole selector
      const grantRoleSel = "0x2f2ff15d";
      const criticalCalldata = ethers.solidityPacked(
        ["bytes4", "bytes32", "address"],
        [grantRoleSel, ethers.ZeroHash, ethers.ZeroAddress]
      );
      const delay = await timelock.getRequiredDelay(criticalCalldata);
      expect(delay).to.equal(CRITICAL_DELAY);
    });

    it("Should schedule routine operation with 48h delay", async function () {
      const target = token.target;
      const value = 0;
      // A non-critical call: transfer(address,uint256)
      const transferSel = token.interface.encodeFunctionData(
        "transfer", [voter1.address, ethers.parseEther("1")]
      );
      const predecessor = ethers.ZeroHash;
      const salt = ethers.id("routine-test");

      await timelock.connect(owner).schedule(
        target, value, transferSel, predecessor, salt, ROUTINE_DELAY
      );

      const operationId = await timelock.hashOperation(
        target, value, transferSel, predecessor, salt
      );
      expect(await timelock.isOperation(operationId)).to.be.true;
    });

    it("Should reject critical operation with insufficient delay", async function () {
      const target = core.target;
      const value = 0;
      // grantRole is critical
      const grantRoleData = core.interface.encodeFunctionData(
        "grantRole",
        [ethers.id("TEST_ROLE"), voter1.address]
      );
      const predecessor = ethers.ZeroHash;
      const salt = ethers.id("critical-fail-test");

      // Try with routine delay (48h) for a critical call — should fail
      await expect(
        timelock.connect(owner).schedule(
          target, value, grantRoleData, predecessor, salt, ROUTINE_DELAY
        )
      ).to.be.revertedWithCustomError(
        timelock, "DelayBelowCriticalMinimum"
      );
    });

    it("Should accept critical operation with CRITICAL_DELAY", async function () {
      const target = core.target;
      const value = 0;
      const grantRoleData = core.interface.encodeFunctionData(
        "grantRole",
        [ethers.id("TEST_ROLE"), voter1.address]
      );
      const predecessor = ethers.ZeroHash;
      const salt = ethers.id("critical-pass-test");

      await timelock.connect(owner).schedule(
        target, value, grantRoleData, predecessor, salt, CRITICAL_DELAY
      );

      const operationId = await timelock.hashOperation(
        target, value, grantRoleData, predecessor, salt
      );
      expect(await timelock.isOperation(operationId)).to.be.true;
    });

    it("Should enforce batch critical delay if any call is critical", async function () {
      const targets = [token.target, core.target];
      const values = [0, 0];
      const payloads = [
        // Routine call
        token.interface.encodeFunctionData(
          "transfer", [voter1.address, ethers.parseEther("1")]
        ),
        // Critical call (grantRole)
        core.interface.encodeFunctionData(
          "grantRole", [ethers.id("TEST_ROLE"), voter1.address]
        )
      ];
      const predecessor = ethers.ZeroHash;
      const salt = ethers.id("batch-critical-test");

      // Routine delay should fail since batch contains critical
      await expect(
        timelock.connect(owner).scheduleBatch(
          targets, values, payloads, predecessor, salt, ROUTINE_DELAY
        )
      ).to.be.revertedWithCustomError(
        timelock, "DelayBelowCriticalMinimum"
      );

      // Critical delay should succeed
      await timelock.connect(owner).scheduleBatch(
        targets, values, payloads, predecessor, salt, CRITICAL_DELAY
      );
    });

    it("Should execute operation after delay", async function () {
      // Mint tokens to timelock so it can transfer
      await token.mint(timelock.target, ethers.parseEther("100"));

      const target = token.target;
      const value = 0;
      const transferData = token.interface.encodeFunctionData(
        "transfer", [voter3.address, ethers.parseEther("50")]
      );
      const predecessor = ethers.ZeroHash;
      const salt = ethers.id("execute-test");

      await timelock.connect(owner).schedule(
        target, value, transferData, predecessor, salt, ROUTINE_DELAY
      );

      // Try executing before delay — should fail
      await expect(
        timelock.execute(target, value, transferData, predecessor, salt)
      ).to.be.reverted;

      // Fast-forward past delay
      await time.increase(ROUTINE_DELAY + 1);

      const balBefore = await token.balanceOf(voter3.address);
      await timelock.execute(target, value, transferData, predecessor, salt);
      const balAfter = await token.balanceOf(voter3.address);

      expect(balAfter - balBefore).to.equal(ethers.parseEther("50"));
    });
  });

  // =========================================================================
  // 3. EmergencyGuardian
  // =========================================================================
  describe("EmergencyGuardian", function () {
    beforeEach(deployFullStack);

    it("Should deploy with 5 guardians", async function () {
      expect(await guardian.guardianCount()).to.equal(5);
      expect(await guardian.isGuardian(guardian1.address)).to.be.true;
      expect(await guardian.isGuardian(guardian2.address)).to.be.true;
      expect(await guardian.isGuardian(guardian3.address)).to.be.true;
      expect(await guardian.isGuardian(guardian4.address)).to.be.true;
      expect(await guardian.isGuardian(guardian5.address)).to.be.true;
    });

    it("Should reject deployment with fewer than 5 guardians", async function () {
      const Guardian = await ethers.getContractFactory("EmergencyGuardian");
      await expect(
        Guardian.deploy(timelock.target, [
          guardian1.address, guardian2.address, guardian3.address
        ])
      ).to.be.revertedWithCustomError(Guardian, "BelowMinGuardians");
    });

    it("Should reject deployment with zero address timelock", async function () {
      const Guardian = await ethers.getContractFactory("EmergencyGuardian");
      await expect(
        Guardian.deploy(ethers.ZeroAddress, [
          guardian1.address, guardian2.address, guardian3.address,
          guardian4.address, guardian5.address
        ])
      ).to.be.revertedWithCustomError(Guardian, "InvalidAddress");
    });

    it("Should reject deployment with duplicate guardians", async function () {
      const Guardian = await ethers.getContractFactory("EmergencyGuardian");
      await expect(
        Guardian.deploy(timelock.target, [
          guardian1.address, guardian2.address, guardian3.address,
          guardian4.address, guardian1.address // duplicate
        ])
      ).to.be.revertedWithCustomError(Guardian, "AlreadyGuardian");
    });

    it("Should have immutable timelock reference", async function () {
      expect(await guardian.TIMELOCK()).to.equal(timelock.target);
    });

    it("Should have CANCEL_THRESHOLD of 3", async function () {
      expect(await guardian.CANCEL_THRESHOLD()).to.equal(3);
    });

    it("Should have MIN_GUARDIANS of 5", async function () {
      expect(await guardian.MIN_GUARDIANS()).to.equal(5);
    });

    describe("Pause (1-of-N)", function () {
      it("Should reject pause of unregistered contract", async function () {
        await expect(
          guardian.connect(guardian1).pauseContract(core.target)
        ).to.be.revertedWithCustomError(guardian, "NotPausable");
      });

      it("Should reject pause from non-guardian", async function () {
        await expect(
          guardian.connect(owner).pauseContract(core.target)
        ).to.be.revertedWithCustomError(guardian, "NotGuardian");
      });

      it("Should pause a registered pausable contract", async function () {
        // Register core as pausable (via timelock)
        // Since timelock manages guardian, we need to register via timelock
        // For testing, grant PAUSER_ROLE to guardian on core first
        const ADMIN_ROLE = await core.ADMIN_ROLE();
        await core.connect(admin).grantRole(ADMIN_ROLE, guardian.target);

        // Register as pausable through timelock
        // Simulate timelock calling registerPausable
        const timelockSigner = await ethers.getImpersonatedSigner(
          timelock.target
        );
        // Fund the timelock address for gas
        await owner.sendTransaction({
          to: timelock.target,
          value: ethers.parseEther("1")
        });

        await guardian.connect(timelockSigner).registerPausable(core.target);
        expect(await guardian.isPausable(core.target)).to.be.true;

        // Now guardian can pause
        await guardian.connect(guardian1).pauseContract(core.target);

        // Core should be paused (if it has a paused() getter)
        expect(await core.paused()).to.be.true;
      });
    });

    describe("Cancel (3-of-5)", function () {
      let operationId;

      beforeEach(async function () {
        // Schedule an operation in the timelock
        const target = token.target;
        const value = 0;
        const data = token.interface.encodeFunctionData(
          "transfer", [voter1.address, ethers.parseEther("1")]
        );
        const predecessor = ethers.ZeroHash;
        const salt = ethers.id("cancel-test-op");

        await token.mint(timelock.target, ethers.parseEther("100"));

        await timelock.connect(owner).schedule(
          target, value, data, predecessor, salt, ROUTINE_DELAY
        );

        operationId = await timelock.hashOperation(
          target, value, data, predecessor, salt
        );
      });

      it("Should collect cancel signatures from guardians", async function () {
        await guardian.connect(guardian1).signCancel(operationId);
        expect(await guardian.cancelSignatureCount(operationId)).to.equal(1);
        expect(
          await guardian.cancelSignatures(operationId, guardian1.address)
        ).to.be.true;
      });

      it("Should reject duplicate signatures", async function () {
        await guardian.connect(guardian1).signCancel(operationId);
        await expect(
          guardian.connect(guardian1).signCancel(operationId)
        ).to.be.revertedWithCustomError(guardian, "AlreadySigned");
      });

      it("Should reject signatures from non-guardians", async function () {
        await expect(
          guardian.connect(owner).signCancel(operationId)
        ).to.be.revertedWithCustomError(guardian, "NotGuardian");
      });

      it("Should auto-cancel at 3 signatures", async function () {
        await guardian.connect(guardian1).signCancel(operationId);
        await guardian.connect(guardian2).signCancel(operationId);

        // 3rd signature should trigger cancel
        await expect(
          guardian.connect(guardian3).signCancel(operationId)
        ).to.emit(guardian, "OperationCancelled")
          .withArgs(operationId, 3);

        // Operation should no longer be pending in timelock
        expect(await timelock.isOperationPending(operationId)).to.be.false;
      });

      it("Should emit CancelSigned events", async function () {
        await expect(
          guardian.connect(guardian1).signCancel(operationId)
        ).to.emit(guardian, "CancelSigned")
          .withArgs(operationId, guardian1.address, 1);
      });
    });

    describe("Guardian Management (Timelock-only)", function () {
      let timelockSigner;

      beforeEach(async function () {
        timelockSigner = await ethers.getImpersonatedSigner(timelock.target);
        await owner.sendTransaction({
          to: timelock.target,
          value: ethers.parseEther("1")
        });
      });

      it("Should add guardian via timelock", async function () {
        const [,,,,,,,,,,, newGuardian] = await ethers.getSigners();
        await guardian.connect(timelockSigner).addGuardian(newGuardian.address);

        expect(await guardian.isGuardian(newGuardian.address)).to.be.true;
        expect(await guardian.guardianCount()).to.equal(6);
      });

      it("Should reject addGuardian from non-timelock", async function () {
        const [,,,,,,,,,,, newGuardian] = await ethers.getSigners();
        await expect(
          guardian.connect(owner).addGuardian(newGuardian.address)
        ).to.be.revertedWithCustomError(guardian, "NotTimelock");
      });

      it("Should reject adding zero address guardian", async function () {
        await expect(
          guardian.connect(timelockSigner).addGuardian(ethers.ZeroAddress)
        ).to.be.revertedWithCustomError(guardian, "InvalidAddress");
      });

      it("Should reject adding existing guardian", async function () {
        await expect(
          guardian.connect(timelockSigner).addGuardian(guardian1.address)
        ).to.be.revertedWithCustomError(guardian, "AlreadyGuardian");
      });

      it("Should remove guardian via timelock when above minimum", async function () {
        // First add a 6th guardian
        const [,,,,,,,,,,, newGuardian] = await ethers.getSigners();
        await guardian.connect(timelockSigner).addGuardian(newGuardian.address);

        // Now remove one (6 → 5, still above MIN_GUARDIANS)
        await guardian.connect(timelockSigner).removeGuardian(
          newGuardian.address
        );

        expect(await guardian.isGuardian(newGuardian.address)).to.be.false;
        expect(await guardian.guardianCount()).to.equal(5);
      });

      it("Should reject removal if it drops below MIN_GUARDIANS", async function () {
        // Currently at exactly 5 (MIN_GUARDIANS)
        await expect(
          guardian.connect(timelockSigner).removeGuardian(guardian1.address)
        ).to.be.revertedWithCustomError(guardian, "BelowMinGuardians");
      });

      it("Should register and deregister pausable contracts", async function () {
        await guardian.connect(timelockSigner).registerPausable(core.target);
        expect(await guardian.isPausable(core.target)).to.be.true;
        expect(await guardian.pausableCount()).to.equal(1);

        await guardian.connect(timelockSigner).deregisterPausable(core.target);
        expect(await guardian.isPausable(core.target)).to.be.false;
        expect(await guardian.pausableCount()).to.equal(0);
      });
    });
  });

  // =========================================================================
  // 4. OmniGovernance
  // =========================================================================
  describe("OmniGovernance", function () {
    beforeEach(deployFullStack);

    describe("Initialization", function () {
      it("Should be initialized with correct references", async function () {
        expect(await governance.omniCoin()).to.equal(token.target);
        expect(await governance.omniCore()).to.equal(core.target);
        expect(await governance.timelock()).to.equal(timelock.target);
      });

      it("Should have correct constants", async function () {
        expect(await governance.VOTING_DELAY()).to.equal(VOTING_DELAY);
        expect(await governance.VOTING_PERIOD()).to.equal(VOTING_PERIOD);
        expect(await governance.PROPOSAL_THRESHOLD()).to.equal(
          PROPOSAL_THRESHOLD
        );
        expect(await governance.QUORUM_BPS()).to.equal(QUORUM_BPS);
        expect(await governance.MAX_ACTIONS()).to.equal(10);
      });

      it("Should reject re-initialization", async function () {
        await expect(
          governance.initialize(
            token.target, core.target, timelock.target, admin.address
          )
        ).to.be.reverted;
      });

      it("Should reject zero address in initialization", async function () {
        const Gov = await ethers.getContractFactory("OmniGovernance");
        await expect(
          upgrades.deployProxy(
            Gov,
            [ethers.ZeroAddress, core.target, timelock.target, admin.address],
            { initializer: "initialize", kind: "uups" }
          )
        ).to.be.revertedWithCustomError(Gov, "InvalidAddress");
      });
    });

    describe("Proposal Creation", function () {
      it("Should create a ROUTINE proposal", async function () {
        // Need 1 block to pass so getPastVotes works
        await mine(1);

        const targets = [token.target];
        const values = [0];
        const calldatas = [
          token.interface.encodeFunctionData(
            "transfer", [voter3.address, ethers.parseEther("1")]
          )
        ];
        const description = "Transfer 1 XOM to voter3";

        const tx = await governance.connect(proposer).propose(
          0, // ROUTINE
          targets, values, calldatas, description
        );

        await expect(tx).to.emit(governance, "ProposalCreated");
        expect(await governance.proposalCount()).to.equal(1);
      });

      it("Should create a CRITICAL proposal", async function () {
        await mine(1);

        const targets = [core.target];
        const values = [0];
        const calldatas = [
          core.interface.encodeFunctionData(
            "grantRole",
            [ethers.id("TEST_ROLE"), voter1.address]
          )
        ];

        const tx = await governance.connect(proposer).propose(
          1, // CRITICAL
          targets, values, calldatas, "Grant test role"
        );

        const receipt = await tx.wait();
        const event = receipt.logs.find(
          log => log.fragment && log.fragment.name === "ProposalCreated"
        );
        expect(event.args.proposalType).to.equal(1); // CRITICAL
      });

      it("Should reject proposal from user below threshold", async function () {
        await mine(1);

        const [,,,,,,,,,,, noTokenUser] = await ethers.getSigners();
        const targets = [token.target];
        const values = [0];
        const calldatas = [
          token.interface.encodeFunctionData(
            "transfer", [voter3.address, ethers.parseEther("1")]
          )
        ];

        await expect(
          governance.connect(noTokenUser).propose(
            0, targets, values, calldatas, "Should fail"
          )
        ).to.be.revertedWithCustomError(governance, "InsufficientVotingPower");
      });

      it("Should reject proposal with empty actions", async function () {
        await mine(1);

        await expect(
          governance.connect(proposer).propose(
            0, [], [], [], "Empty actions"
          )
        ).to.be.revertedWithCustomError(governance, "InvalidActionsLength");
      });

      it("Should reject proposal with > MAX_ACTIONS", async function () {
        await mine(1);

        const targets = new Array(11).fill(token.target);
        const values = new Array(11).fill(0);
        const calldatas = new Array(11).fill("0x");

        await expect(
          governance.connect(proposer).propose(
            0, targets, values, calldatas, "Too many"
          )
        ).to.be.revertedWithCustomError(governance, "TooManyActions");
      });

      it("Should reject proposal with mismatched array lengths", async function () {
        await mine(1);

        await expect(
          governance.connect(proposer).propose(
            0,
            [token.target, core.target], // 2 targets
            [0], // 1 value
            ["0x"], // 1 calldata
            "Mismatched"
          )
        ).to.be.revertedWithCustomError(governance, "InvalidActionsLength");
      });
    });

    describe("Voting", function () {
      let proposalId;

      beforeEach(async function () {
        await mine(1);

        const targets = [token.target];
        const values = [0];
        const calldatas = [
          token.interface.encodeFunctionData(
            "transfer", [voter3.address, ethers.parseEther("1")]
          )
        ];

        const tx = await governance.connect(proposer).propose(
          0, targets, values, calldatas, "Voting test"
        );
        const receipt = await tx.wait();
        proposalId = receipt.logs.find(
          log => log.fragment && log.fragment.name === "ProposalCreated"
        ).args.proposalId;
      });

      it("Should reject votes before voting delay", async function () {
        await expect(
          governance.connect(voter1).castVote(proposalId, 1)
        ).to.be.revertedWithCustomError(
          governance, "InvalidProposalState"
        );
      });

      it("Should accept votes after voting delay", async function () {
        await time.increase(VOTING_DELAY + 1);

        await governance.connect(voter1).castVote(proposalId, 1); // For
        expect(await governance.hasVoted(proposalId, voter1.address)).to.be.true;
      });

      it("Should count For/Against/Abstain votes correctly", async function () {
        await time.increase(VOTING_DELAY + 1);

        await governance.connect(voter1).castVote(proposalId, 1); // For
        await governance.connect(voter2).castVote(proposalId, 0); // Against
        await governance.connect(voter3).castVote(proposalId, 2); // Abstain

        const proposal = await governance.proposals(proposalId);
        expect(proposal.forVotes).to.equal(ethers.parseEther("50000"));
        expect(proposal.againstVotes).to.equal(ethers.parseEther("40000"));
        expect(proposal.abstainVotes).to.equal(ethers.parseEther("30000"));
      });

      it("Should prevent double voting", async function () {
        await time.increase(VOTING_DELAY + 1);

        await governance.connect(voter1).castVote(proposalId, 1);

        await expect(
          governance.connect(voter1).castVote(proposalId, 0)
        ).to.be.revertedWithCustomError(governance, "AlreadyVoted");
      });

      it("Should reject invalid vote type", async function () {
        await time.increase(VOTING_DELAY + 1);

        await expect(
          governance.connect(voter1).castVote(proposalId, 3)
        ).to.be.revertedWithCustomError(governance, "InvalidVoteType");
      });

      it("Should reject votes after voting period", async function () {
        await time.increase(VOTING_DELAY + VOTING_PERIOD + 1);

        await expect(
          governance.connect(voter1).castVote(proposalId, 1)
        ).to.be.revertedWithCustomError(
          governance, "InvalidProposalState"
        );
      });

      it("Should reject vote from user with zero voting power", async function () {
        await time.increase(VOTING_DELAY + 1);

        const [,,,,,,,,,,, zeroUser] = await ethers.getSigners();
        await expect(
          governance.connect(zeroUser).castVote(proposalId, 1)
        ).to.be.revertedWithCustomError(governance, "ZeroVotingPower");
      });

      it("Should emit VoteCast event with correct weight", async function () {
        await time.increase(VOTING_DELAY + 1);

        await expect(
          governance.connect(voter1).castVote(proposalId, 1)
        ).to.emit(governance, "VoteCast")
          .withArgs(
            proposalId, voter1.address, 1, ethers.parseEther("50000")
          );
      });
    });

    describe("Vote by Signature (EIP-712)", function () {
      let proposalId;

      beforeEach(async function () {
        await mine(1);

        const targets = [token.target];
        const values = [0];
        const calldatas = [
          token.interface.encodeFunctionData(
            "transfer", [voter3.address, ethers.parseEther("1")]
          )
        ];

        const tx = await governance.connect(proposer).propose(
          0, targets, values, calldatas, "Sig vote test"
        );
        const receipt = await tx.wait();
        proposalId = receipt.logs.find(
          log => log.fragment && log.fragment.name === "ProposalCreated"
        ).args.proposalId;

        await time.increase(VOTING_DELAY + 1);
      });

      it("Should accept valid EIP-712 vote signature", async function () {
        const nonce = await governance.voteNonce(voter1.address);

        // Build EIP-712 domain
        const domain = {
          name: "OmniGovernance",
          version: "1",
          chainId: (await ethers.provider.getNetwork()).chainId,
          verifyingContract: governance.target
        };

        const types = {
          Vote: [
            { name: "proposalId", type: "uint256" },
            { name: "support", type: "uint8" },
            { name: "nonce", type: "uint256" }
          ]
        };

        const message = {
          proposalId: proposalId,
          support: 1, // For
          nonce: nonce
        };

        const sig = await voter1.signTypedData(domain, types, message);
        const { v, r, s } = ethers.Signature.from(sig);

        // Submit via relayer (owner, not voter1)
        await governance.connect(owner).castVoteBySig(
          proposalId, 1, nonce, v, r, s
        );

        expect(await governance.hasVoted(proposalId, voter1.address)).to.be.true;
      });

      it("Should increment nonce after vote by sig", async function () {
        const nonceBefore = await governance.voteNonce(voter1.address);

        const domain = {
          name: "OmniGovernance",
          version: "1",
          chainId: (await ethers.provider.getNetwork()).chainId,
          verifyingContract: governance.target
        };

        const types = {
          Vote: [
            { name: "proposalId", type: "uint256" },
            { name: "support", type: "uint8" },
            { name: "nonce", type: "uint256" }
          ]
        };

        const message = {
          proposalId: proposalId,
          support: 1,
          nonce: nonceBefore
        };

        const sig = await voter1.signTypedData(domain, types, message);
        const { v, r, s } = ethers.Signature.from(sig);

        await governance.connect(owner).castVoteBySig(
          proposalId, 1, nonceBefore, v, r, s
        );

        const nonceAfter = await governance.voteNonce(voter1.address);
        expect(nonceAfter).to.equal(nonceBefore + 1n);
      });

      it("Should reject vote with wrong nonce", async function () {
        const domain = {
          name: "OmniGovernance",
          version: "1",
          chainId: (await ethers.provider.getNetwork()).chainId,
          verifyingContract: governance.target
        };

        const types = {
          Vote: [
            { name: "proposalId", type: "uint256" },
            { name: "support", type: "uint8" },
            { name: "nonce", type: "uint256" }
          ]
        };

        const wrongNonce = 999n;
        const message = {
          proposalId: proposalId,
          support: 1,
          nonce: wrongNonce
        };

        const sig = await voter1.signTypedData(domain, types, message);
        const { v, r, s } = ethers.Signature.from(sig);

        await expect(
          governance.connect(owner).castVoteBySig(
            proposalId, 1, wrongNonce, v, r, s
          )
        ).to.be.revertedWithCustomError(governance, "InvalidNonce");
      });
    });

    describe("Proposal Lifecycle (queue, execute, cancel)", function () {
      let proposalId;

      beforeEach(async function () {
        await mine(1);

        // Mint to timelock for execution
        await token.mint(timelock.target, ethers.parseEther("1000"));

        const targets = [token.target];
        const values = [0];
        const calldatas = [
          token.interface.encodeFunctionData(
            "transfer", [voter3.address, ethers.parseEther("10")]
          )
        ];

        const tx = await governance.connect(proposer).propose(
          0, // ROUTINE
          targets, values, calldatas, "Lifecycle test"
        );
        const receipt = await tx.wait();
        proposalId = receipt.logs.find(
          log => log.fragment && log.fragment.name === "ProposalCreated"
        ).args.proposalId;

        // Vote to pass (need quorum = 4% of total supply)
        await time.increase(VOTING_DELAY + 1);

        // owner has ~4.13B, well above 4% quorum
        await governance.connect(owner).castVote(proposalId, 1);
        await governance.connect(voter1).castVote(proposalId, 1);
        await governance.connect(voter2).castVote(proposalId, 1);

        // Wait for voting to end
        await time.increase(VOTING_PERIOD + 1);
      });

      it("Should show Succeeded state after passing", async function () {
        const currentState = await governance.state(proposalId);
        expect(currentState).to.equal(3); // Succeeded
      });

      it("Should queue succeeded proposal", async function () {
        await expect(
          governance.queue(proposalId)
        ).to.emit(governance, "ProposalQueued");

        const currentState = await governance.state(proposalId);
        expect(currentState).to.equal(4); // Queued
      });

      it("Should execute queued proposal after timelock delay", async function () {
        await governance.queue(proposalId);

        // Can't execute before delay
        await expect(
          governance.execute(proposalId)
        ).to.be.reverted;

        // Wait for routine delay (48h)
        await time.increase(ROUTINE_DELAY + 1);

        const balBefore = await token.balanceOf(voter3.address);
        await governance.execute(proposalId);
        const balAfter = await token.balanceOf(voter3.address);

        expect(balAfter - balBefore).to.equal(ethers.parseEther("10"));

        const currentState = await governance.state(proposalId);
        expect(currentState).to.equal(5); // Executed
      });

      it("Should cancel proposal by proposer", async function () {
        await expect(
          governance.connect(proposer).cancel(proposalId)
        ).to.emit(governance, "ProposalCancelled")
          .withArgs(proposalId);

        const currentState = await governance.state(proposalId);
        expect(currentState).to.equal(6); // Cancelled
      });

      it("Should cancel proposal by admin", async function () {
        await governance.connect(admin).cancel(proposalId);
        const currentState = await governance.state(proposalId);
        expect(currentState).to.equal(6); // Cancelled
      });

      it("Should reject cancel from non-proposer non-admin", async function () {
        await expect(
          governance.connect(voter3).cancel(proposalId)
        ).to.be.revertedWithCustomError(
          governance, "InvalidProposalState"
        );
      });

      it("Should show Defeated for proposal with more against", async function () {
        await mine(1);

        // Create a new proposal
        const targets = [token.target];
        const values = [0];
        const calldatas = [
          token.interface.encodeFunctionData(
            "transfer", [voter3.address, ethers.parseEther("1")]
          )
        ];

        const tx2 = await governance.connect(proposer).propose(
          0, targets, values, calldatas, "Defeat test"
        );
        const receipt2 = await tx2.wait();
        const proposalId2 = receipt2.logs.find(
          log => log.fragment && log.fragment.name === "ProposalCreated"
        ).args.proposalId;

        await time.increase(VOTING_DELAY + 1);

        // Vote to defeat: owner has majority
        await governance.connect(owner).castVote(proposalId2, 0); // Against
        await governance.connect(voter1).castVote(proposalId2, 1); // For

        await time.increase(VOTING_PERIOD + 1);

        const currentState = await governance.state(proposalId2);
        expect(currentState).to.equal(2); // Defeated
      });

      it("Should show Expired when queue deadline passes", async function () {
        // Don't queue, wait for QUEUE_DEADLINE to expire
        await time.increase(14 * 24 * 60 * 60 + 1); // 14 days + 1

        const currentState = await governance.state(proposalId);
        expect(currentState).to.equal(7); // Expired
      });
    });

    describe("Voting Power (Delegation + Staking)", function () {
      it("Should include delegated XOM in voting power", async function () {
        // voter1 delegated to self with 50k
        const power = await governance.getVotingPower(voter1.address);
        expect(power).to.equal(ethers.parseEther("50000"));
      });

      it("Should include staked XOM in voting power", async function () {
        const stakeAmount = ethers.parseEther("20000");
        await token.connect(voter1).approve(core.target, stakeAmount);
        await core.connect(voter1).stake(stakeAmount, 1, 0);

        // voter1: 30k delegated (50k - 20k transferred to core) + 20k staked
        const power = await governance.getVotingPower(voter1.address);
        expect(power).to.equal(ethers.parseEther("50000"));
      });

      it("Should allow proposal with staked-only balance", async function () {
        const [,,,,,,,,,,, stakerOnly] = await ethers.getSigners();
        await token.mint(stakerOnly.address, ethers.parseEther("10000"));
        await token.connect(stakerOnly).delegate(stakerOnly.address);

        // Stake all tokens
        await token.connect(stakerOnly).approve(
          core.target, ethers.parseEther("10000")
        );
        await core.connect(stakerOnly).stake(
          ethers.parseEther("10000"), 1, 0
        );

        await mine(1);

        // stakerOnly: 0 delegated (tokens transferred to core) + 10k staked = 10k
        const targets = [token.target];
        const values = [0];
        const calldatas = [
          token.interface.encodeFunctionData(
            "transfer", [voter3.address, ethers.parseEther("1")]
          )
        ];

        await expect(
          governance.connect(stakerOnly).propose(
            0, targets, values, calldatas, "Staker-only proposal"
          )
        ).to.not.be.reverted;
      });
    });

    describe("Ossification", function () {
      it("Should not be ossified initially", async function () {
        expect(await governance.isOssified()).to.be.false;
      });

      it("Should ossify when called by admin", async function () {
        await expect(
          governance.connect(admin).ossify()
        ).to.emit(governance, "ContractOssified");

        expect(await governance.isOssified()).to.be.true;
      });

      it("Should reject ossify from non-admin", async function () {
        await expect(
          governance.connect(voter1).ossify()
        ).to.be.reverted;
      });

      it("Should block upgrades after ossification", async function () {
        await governance.connect(admin).ossify();

        // Must connect as admin (who has ADMIN_ROLE) to reach the ossification check
        const GovV2 = await ethers.getContractFactory(
          "OmniGovernance", admin
        );
        await expect(
          upgrades.upgradeProxy(governance.target, GovV2)
        ).to.be.revertedWithCustomError(governance, "ContractIsOssified");
      });
    });
  });

  // =========================================================================
  // 5. OmniCore Staking Snapshots
  // =========================================================================
  describe("OmniCore Staking Snapshots", function () {
    beforeEach(deployFullStack);

    it("Should record staking checkpoint on stake()", async function () {
      const stakeAmount = ethers.parseEther("10000");
      await token.connect(voter1).approve(core.target, stakeAmount);
      await core.connect(voter1).stake(stakeAmount, 1, 0);

      const blockNumber = await ethers.provider.getBlockNumber();

      const stakedAt = await core.getStakedAt(voter1.address, blockNumber);
      expect(stakedAt).to.equal(stakeAmount);
    });

    it("Should record zero checkpoint on unlock()", async function () {
      const stakeAmount = ethers.parseEther("10000");
      await token.connect(voter1).approve(core.target, stakeAmount);
      await core.connect(voter1).stake(stakeAmount, 1, 0);

      const stakeBlock = await ethers.provider.getBlockNumber();

      // Unlock (duration 0 means no lock)
      await core.connect(voter1).unlock();

      const unlockBlock = await ethers.provider.getBlockNumber();

      // At stake block, should show staked amount
      const stakedAtStake = await core.getStakedAt(
        voter1.address, stakeBlock
      );
      expect(stakedAtStake).to.equal(stakeAmount);

      // At unlock block, should show zero
      const stakedAtUnlock = await core.getStakedAt(
        voter1.address, unlockBlock
      );
      expect(stakedAtUnlock).to.equal(0);
    });

    it("Should return 0 for blocks before any stake", async function () {
      const blockBefore = await ethers.provider.getBlockNumber();

      const stakedAt = await core.getStakedAt(voter1.address, blockBefore);
      expect(stakedAt).to.equal(0);
    });

    it("Should preserve history across multiple stake/unstake", async function () {
      // First stake
      const amount1 = ethers.parseEther("5000");
      await token.connect(voter1).approve(core.target, amount1);
      await core.connect(voter1).stake(amount1, 1, 0);
      const block1 = await ethers.provider.getBlockNumber();

      // Unlock
      await core.connect(voter1).unlock();
      const block2 = await ethers.provider.getBlockNumber();

      // Second stake (different amount, still tier 1 since < 1M XOM)
      const amount2 = ethers.parseEther("15000");
      await token.connect(voter1).approve(core.target, amount2);
      await core.connect(voter1).stake(amount2, 1, 0);
      const block3 = await ethers.provider.getBlockNumber();

      // Verify history
      expect(await core.getStakedAt(voter1.address, block1)).to.equal(amount1);
      expect(await core.getStakedAt(voter1.address, block2)).to.equal(0);
      expect(await core.getStakedAt(voter1.address, block3)).to.equal(amount2);
    });

    it("Should be used by GovernanceV2 for snapshot voting", async function () {
      // Stake tokens before proposal
      const stakeAmount = ethers.parseEther("20000");
      await token.connect(voter1).approve(core.target, stakeAmount);
      await core.connect(voter1).stake(stakeAmount, 1, 0);

      await mine(1);

      // Create proposal (snapshot taken at this block)
      const targets = [token.target];
      const values = [0];
      const calldatas = [
        token.interface.encodeFunctionData(
          "transfer", [voter3.address, ethers.parseEther("1")]
        )
      ];

      const tx = await governance.connect(proposer).propose(
        0, targets, values, calldatas, "Snapshot staking test"
      );
      const receipt = await tx.wait();
      const proposalId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ProposalCreated"
      ).args.proposalId;

      const proposal = await governance.proposals(proposalId);
      const snapshotBlock = proposal.snapshotBlock;

      // Must mine a block so snapshotBlock is in the past
      // (getPastVotes requires block < current block)
      await mine(1);

      // Voting power at snapshot should include staked amount
      const votingPowerAtSnapshot = await governance.getVotingPowerAt(
        voter1.address, snapshotBlock
      );

      // delegated (50k - 20k transferred) + staked (20k) = 50k
      expect(votingPowerAtSnapshot).to.equal(ethers.parseEther("50000"));
    });
  });

  // =========================================================================
  // 6. OmniBridge UUPS
  // =========================================================================
  describe("OmniBridge UUPS", function () {
    let bridge;

    beforeEach(async function () {
      await deployFullStack();

      // Deploy mock Warp Messenger at the precompile address
      const WARP_MESSENGER_ADDRESS =
        "0x0200000000000000000000000000000000000005";
      const MockWarpMessenger = await ethers.getContractFactory(
        "MockWarpMessenger"
      );
      const mockWarp = await MockWarpMessenger.deploy();
      const mockCode = await ethers.provider.getCode(mockWarp.target);
      await ethers.provider.send("hardhat_setCode", [
        WARP_MESSENGER_ADDRESS,
        mockCode
      ]);
      const mockBlockchainId = await ethers.provider.getStorage(
        mockWarp.target, 0
      );
      await ethers.provider.send("hardhat_setStorageAt", [
        WARP_MESSENGER_ADDRESS,
        "0x0",
        mockBlockchainId
      ]);

      // Deploy OmniBridge via UUPS proxy
      const OmniBridge = await ethers.getContractFactory("OmniBridge");
      bridge = await upgrades.deployProxy(
        OmniBridge,
        [core.target, admin.address],
        { initializer: "initialize", kind: "uups" }
      );
    });

    it("Should initialize with correct references", async function () {
      expect(await bridge.core()).to.equal(core.target);
    });

    it("Should have ADMIN_ROLE set", async function () {
      const ADMIN_ROLE = await bridge.ADMIN_ROLE();
      expect(await bridge.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
    });

    it("Should reject re-initialization", async function () {
      await expect(
        bridge.initialize(core.target, admin.address)
      ).to.be.reverted;
    });

    it("Should not be ossified initially", async function () {
      expect(await bridge.isOssified()).to.be.false;
    });

    it("Should ossify when called by admin", async function () {
      await expect(
        bridge.connect(admin).ossify()
      ).to.emit(bridge, "ContractOssified");

      expect(await bridge.isOssified()).to.be.true;
    });

    it("Should block upgrades after ossification", async function () {
      await bridge.connect(admin).ossify();

      // Must connect as admin (who has ADMIN_ROLE) to reach ossification check
      const OmniBridge = await ethers.getContractFactory(
        "OmniBridge", admin
      );
      await expect(
        upgrades.upgradeProxy(bridge.target, OmniBridge)
      ).to.be.revertedWithCustomError(bridge, "ContractIsOssified");
    });
  });

  // =========================================================================
  // 7. OmniCore Ossification
  // =========================================================================
  describe("OmniCore Ossification", function () {
    beforeEach(deployFullStack);

    it("Should not be ossified initially", async function () {
      expect(await core.isOssified()).to.be.false;
    });

    it("Should ossify when called by admin", async function () {
      await expect(
        core.connect(admin).ossify()
      ).to.emit(core, "ContractOssified");

      expect(await core.isOssified()).to.be.true;
    });

    it("Should reject ossify from non-admin", async function () {
      await expect(
        core.connect(voter1).ossify()
      ).to.be.reverted;
    });

    it("Should block upgrades after ossification", async function () {
      await core.connect(admin).ossify();

      // Must connect as admin (who has ADMIN_ROLE) to reach ossification check
      const OmniCore = await ethers.getContractFactory("OmniCore", admin);
      await expect(
        upgrades.upgradeProxy(core.target, OmniCore)
      ).to.be.revertedWithCustomError(core, "ContractIsOssified");
    });

    it("Should still function normally after ossification", async function () {
      await core.connect(admin).ossify();

      // Staking should still work
      const stakeAmount = ethers.parseEther("5000");
      await token.connect(voter1).approve(core.target, stakeAmount);
      await core.connect(voter1).stake(stakeAmount, 1, 0);

      const stake = await core.getStake(voter1.address);
      expect(stake.amount).to.equal(stakeAmount);
      expect(stake.active).to.be.true;
    });
  });

  // =========================================================================
  // 8. Integration: Full Governance Flow
  // =========================================================================
  describe("Full Governance Integration", function () {
    beforeEach(deployFullStack);

    it("Should execute a full ROUTINE governance flow end-to-end", async function () {
      // Mint tokens to timelock for the proposal action
      await token.mint(timelock.target, ethers.parseEther("500"));

      await mine(1);

      // 1. Propose
      const targets = [token.target];
      const values = [0];
      const calldatas = [
        token.interface.encodeFunctionData(
          "transfer", [voter3.address, ethers.parseEther("100")]
        )
      ];

      const tx = await governance.connect(proposer).propose(
        0, // ROUTINE
        targets, values, calldatas,
        "Transfer 100 XOM from treasury to voter3"
      );
      const receipt = await tx.wait();
      const proposalId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ProposalCreated"
      ).args.proposalId;

      // 2. Wait for voting delay
      await time.increase(VOTING_DELAY + 1);

      // 3. Vote (owner has >4% for quorum)
      await governance.connect(owner).castVote(proposalId, 1); // For
      await governance.connect(voter1).castVote(proposalId, 1); // For
      await governance.connect(voter2).castVote(proposalId, 1); // For

      // 4. Wait for voting period
      await time.increase(VOTING_PERIOD + 1);

      // 5. Check state is Succeeded
      expect(await governance.state(proposalId)).to.equal(3); // Succeeded

      // 6. Queue
      await governance.queue(proposalId);
      expect(await governance.state(proposalId)).to.equal(4); // Queued

      // 7. Wait for timelock delay (48h for ROUTINE)
      await time.increase(ROUTINE_DELAY + 1);

      // 8. Execute
      const balBefore = await token.balanceOf(voter3.address);
      await governance.execute(proposalId);
      const balAfter = await token.balanceOf(voter3.address);

      expect(balAfter - balBefore).to.equal(ethers.parseEther("100"));
      expect(await governance.state(proposalId)).to.equal(5); // Executed
    });

    it("Should handle guardian emergency cancel of a queued proposal", async function () {
      await token.mint(timelock.target, ethers.parseEther("500"));

      await mine(1);

      // Propose and pass
      const targets = [token.target];
      const values = [0];
      const calldatas = [
        token.interface.encodeFunctionData(
          "transfer", [voter3.address, ethers.parseEther("100")]
        )
      ];

      const tx = await governance.connect(proposer).propose(
        0, targets, values, calldatas, "Guardian cancel test"
      );
      const receipt = await tx.wait();
      const proposalId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "ProposalCreated"
      ).args.proposalId;

      await time.increase(VOTING_DELAY + 1);
      await governance.connect(owner).castVote(proposalId, 1);
      await governance.connect(voter1).castVote(proposalId, 1);
      await time.increase(VOTING_PERIOD + 1);

      // Queue in timelock
      await governance.queue(proposalId);

      // Get the timelock operation ID
      const actions = await governance.getActions(proposalId);
      // Copy frozen arrays so ethers can process them
      const actionTargets = [...actions[0]];
      const actionValues = [...actions[1]];
      const actionCalldatas = [...actions[2]];
      const salt = ethers.keccak256(
        ethers.solidityPacked(
          ["string", "uint256"],
          ["OmniGov", proposalId]
        )
      );
      const timelockId = await timelock.hashOperationBatch(
        actionTargets,
        actionValues,
        actionCalldatas,
        ethers.ZeroHash, // predecessor
        salt
      );

      // 3 guardians sign cancel
      await guardian.connect(guardian1).signCancel(timelockId);
      await guardian.connect(guardian2).signCancel(timelockId);
      await guardian.connect(guardian3).signCancel(timelockId);

      // Operation should be cancelled in timelock
      expect(await timelock.isOperationPending(timelockId)).to.be.false;
    });
  });
});
