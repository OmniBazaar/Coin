const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * Builds an EIP-712 ForwardRequest, signs it with the given signer, and returns
 * the ForwardRequestData struct expected by ERC2771Forwarder.execute().
 *
 * The signed EIP-712 type includes `nonce` (fetched on-chain) but the struct
 * passed to execute() omits it — the forwarder recovers it internally.
 *
 * @param {object} signer - Ethers signer that will produce the EIP-712 signature
 * @param {object} forwarder - Deployed OmniForwarder contract instance
 * @param {string} to - Target contract address
 * @param {string} data - ABI-encoded calldata for the target function
 * @param {object} [overrides] - Optional overrides for nonce, deadline, gas, value
 * @returns {Promise<object>} ForwardRequestData ready for forwarder.execute()
 */
async function buildForwardRequest(signer, forwarder, to, data, overrides = {}) {
  const nonce = overrides.nonce !== undefined
    ? overrides.nonce
    : await forwarder.nonces(signer.address);

  let deadline;
  if (overrides.deadline !== undefined) {
    deadline = overrides.deadline;
  } else {
    // Use EVM block.timestamp (not wall clock) to avoid issues when other tests
    // advance time via evm_increaseTime / time.increaseTo
    const latestBlock = await ethers.provider.getBlock("latest");
    deadline = BigInt(latestBlock.timestamp) + 3600n;
  }

  const gasLimit = overrides.gas !== undefined ? overrides.gas : 500000n;
  const value = overrides.value !== undefined ? overrides.value : 0n;

  // Fetch EIP-712 domain from the forwarder contract (EIP-5267)
  const domainData = await forwarder.eip712Domain();
  const eip712Domain = {
    name: domainData.name,
    version: domainData.version,
    chainId: domainData.chainId,
    verifyingContract: domainData.verifyingContract,
  };

  // The EIP-712 type hash includes nonce even though ForwardRequestData does not
  const types = {
    ForwardRequest: [
      { name: "from", type: "address" },
      { name: "to", type: "address" },
      { name: "value", type: "uint256" },
      { name: "gas", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint48" },
      { name: "data", type: "bytes" },
    ],
  };

  const message = {
    from: signer.address,
    to: to,
    value: value,
    gas: gasLimit,
    nonce: nonce,
    deadline: deadline,
    data: data,
  };

  const signature = await signer.signTypedData(eip712Domain, types, message);

  // Return the ForwardRequestData struct (no nonce field)
  return {
    from: signer.address,
    to: to,
    value: value,
    gas: gasLimit,
    deadline: deadline,
    data: data,
    signature: signature,
  };
}

describe("Gasless Relay — OmniForwarder (ERC-2771)", function () {
  let forwarder;
  let omniCoin;
  let pToken;
  let escrow;
  let owner, validator, user, recipient1, recipient2, seller, registry;

  const INITIAL_USER_BALANCE = ethers.parseEther("10000");

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    owner = signers[0];
    validator = signers[1];
    user = signers[2];
    recipient1 = signers[3];
    recipient2 = signers[4];
    seller = signers[5];
    registry = signers[6];

    // 1. Deploy OmniForwarder
    const OmniForwarder = await ethers.getContractFactory("OmniForwarder");
    forwarder = await OmniForwarder.deploy();
    await forwarder.waitForDeployment();

    // 2. Deploy OmniCoin with forwarder as trusted forwarder
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    omniCoin = await OmniCoin.deploy(await forwarder.getAddress());
    await omniCoin.waitForDeployment();
    await omniCoin.connect(owner).initialize();

    // 3. Deploy a second OmniCoin as pXOM stand-in (with forwarder support)
    pToken = await OmniCoin.deploy(await forwarder.getAddress());
    await pToken.waitForDeployment();
    await pToken.connect(owner).initialize();

    // 4. Fund user with XOM (via owner transfer from genesis supply)
    await omniCoin.connect(owner).transfer(user.address, INITIAL_USER_BALANCE);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 1. Deployment Tests
  // ─────────────────────────────────────────────────────────────────────────
  describe("Deployment", function () {
    it("Should deploy OmniForwarder successfully", async function () {
      const address = await forwarder.getAddress();
      expect(address).to.be.properAddress;
    });

    it("Should return correct EIP-712 domain", async function () {
      const domain = await forwarder.eip712Domain();

      expect(domain.name).to.equal("OmniForwarder");
      expect(domain.version).to.equal("1");
      // Hardhat defaults to chainId 1337 per hardhat.config.js
      expect(domain.chainId).to.equal(1337n);
      expect(domain.verifyingContract).to.equal(await forwarder.getAddress());
    });

    it("Should start nonce at 0 for all addresses", async function () {
      expect(await forwarder.nonces(user.address)).to.equal(0n);
      expect(await forwarder.nonces(validator.address)).to.equal(0n);
      expect(await forwarder.nonces(owner.address)).to.equal(0n);
    });

    it("Should recognize forwarder as trusted by OmniCoin", async function () {
      // OmniCoin inherits ERC2771Context which exposes isTrustedForwarder()
      expect(
        await omniCoin.isTrustedForwarder(await forwarder.getAddress())
      ).to.be.true;
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. Single Relay — ERC20 approve()
  // ─────────────────────────────────────────────────────────────────────────
  describe("Single Relay — OmniCoin ERC20 approve", function () {
    it("Should relay approve() so user sets allowance without paying gas", async function () {
      const spender = validator.address;
      const amount = ethers.parseEther("500");

      // Encode the approve(spender, amount) call
      const calldata = omniCoin.interface.encodeFunctionData("approve", [
        spender,
        amount,
      ]);

      // User signs the ForwardRequest (user has ZERO native gas — only XOM)
      const request = await buildForwardRequest(
        user,
        forwarder,
        await omniCoin.getAddress(),
        calldata
      );

      // Verify the request is valid before executing
      expect(await forwarder.verify(request)).to.be.true;

      // Validator relays the request, paying gas on behalf of user
      await forwarder.connect(validator).execute(request);

      // Verify: allowance is set correctly
      expect(await omniCoin.allowance(user.address, spender)).to.equal(amount);
    });

    it("Should increment user nonce after successful relay", async function () {
      const nonceBefore = await forwarder.nonces(user.address);

      const calldata = omniCoin.interface.encodeFunctionData("approve", [
        validator.address,
        ethers.parseEther("100"),
      ]);

      const request = await buildForwardRequest(
        user,
        forwarder,
        await omniCoin.getAddress(),
        calldata
      );

      await forwarder.connect(validator).execute(request);

      const nonceAfter = await forwarder.nonces(user.address);
      expect(nonceAfter).to.equal(nonceBefore + 1n);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. Single Relay — OmniCoin batchTransfer()
  // ─────────────────────────────────────────────────────────────────────────
  describe("Single Relay — OmniCoin batchTransfer", function () {
    it("Should relay batchTransfer() distributing tokens to multiple recipients", async function () {
      const recipients = [recipient1.address, recipient2.address];
      const amounts = [ethers.parseEther("100"), ethers.parseEther("200")];
      const totalSent = ethers.parseEther("300");

      const calldata = omniCoin.interface.encodeFunctionData("batchTransfer", [
        recipients,
        amounts,
      ]);

      const request = await buildForwardRequest(
        user,
        forwarder,
        await omniCoin.getAddress(),
        calldata
      );

      const userBalanceBefore = await omniCoin.balanceOf(user.address);

      await forwarder.connect(validator).execute(request);

      // Verify: each recipient received the correct amount
      expect(await omniCoin.balanceOf(recipient1.address)).to.equal(amounts[0]);
      expect(await omniCoin.balanceOf(recipient2.address)).to.equal(amounts[1]);

      // Verify: user balance decreased by total sent
      expect(await omniCoin.balanceOf(user.address)).to.equal(
        userBalanceBefore - totalSent
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. Batch Relay — approve + createEscrow
  // ─────────────────────────────────────────────────────────────────────────
  describe("Batch Relay — approve + createEscrow", function () {
    let escrowAddress;

    beforeEach(async function () {
      // Deploy MinimalEscrow with forwarder support
      // Constructor: (omniCoin, privateOmniCoin, registry, feeCollector, feeBps, trustedForwarder)
      const MinimalEscrow = await ethers.getContractFactory("MinimalEscrow");
      escrow = await MinimalEscrow.connect(owner).deploy(
        await omniCoin.getAddress(),
        await pToken.getAddress(),
        registry.address,
        owner.address,     // feeCollector
        100,               // 1% marketplace fee (100 bps)
        await forwarder.getAddress()
      );
      await escrow.waitForDeployment();
      escrowAddress = await escrow.getAddress();
    });

    it("Should atomically approve + createEscrow via executeBatch", async function () {
      const escrowAmount = ethers.parseEther("500");
      const duration = 7 * 24 * 60 * 60; // 7 days

      // Request 1: approve(escrowAddress, amount) on OmniCoin
      const approveCalldata = omniCoin.interface.encodeFunctionData("approve", [
        escrowAddress,
        escrowAmount,
      ]);

      const req1 = await buildForwardRequest(
        user,
        forwarder,
        await omniCoin.getAddress(),
        approveCalldata
      );

      // Request 2: createEscrow(seller, amount, duration) on MinimalEscrow
      // Note: nonce for req2 must be req1.nonce + 1
      const createEscrowCalldata = escrow.interface.encodeFunctionData(
        "createEscrow",
        [seller.address, escrowAmount, duration]
      );

      const req2 = await buildForwardRequest(
        user,
        forwarder,
        escrowAddress,
        createEscrowCalldata,
        { nonce: (await forwarder.nonces(user.address)) + 1n }
      );

      const userBalanceBefore = await omniCoin.balanceOf(user.address);

      // Validator submits both requests atomically
      // executeBatch requires a refundReceiver for unused msg.value
      await forwarder
        .connect(validator)
        .executeBatch([req1, req2], validator.address);

      // Verify: escrow created with user as buyer (NOT the forwarder address)
      const escrowData = await escrow.escrows(1);
      expect(escrowData.buyer).to.equal(user.address);
      expect(escrowData.seller).to.equal(seller.address);
      expect(escrowData.amount).to.equal(escrowAmount);
      expect(escrowData.resolved).to.be.false;

      // Verify: XOM transferred from user to escrow contract
      const userBalanceAfter = await omniCoin.balanceOf(user.address);
      expect(userBalanceBefore - userBalanceAfter).to.equal(escrowAmount);

      // Verify: escrow contract holds the tokens
      expect(await omniCoin.balanceOf(escrowAddress)).to.equal(escrowAmount);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 5. Single Relay — ERC20 transfer (implicit _msgSender)
  // ─────────────────────────────────────────────────────────────────────────
  describe("Single Relay — ERC20 transfer", function () {
    it("Should relay transfer() with user as sender (not forwarder)", async function () {
      const amount = ethers.parseEther("250");

      const calldata = omniCoin.interface.encodeFunctionData("transfer", [
        recipient1.address,
        amount,
      ]);

      const request = await buildForwardRequest(
        user,
        forwarder,
        await omniCoin.getAddress(),
        calldata
      );

      const userBalanceBefore = await omniCoin.balanceOf(user.address);

      await forwarder.connect(validator).execute(request);

      // Verify: transfer executed with user as sender
      expect(await omniCoin.balanceOf(recipient1.address)).to.equal(amount);
      expect(await omniCoin.balanceOf(user.address)).to.equal(
        userBalanceBefore - amount
      );

      // Verify: forwarder's balance is zero (it never held tokens)
      expect(
        await omniCoin.balanceOf(await forwarder.getAddress())
      ).to.equal(0n);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 6. Invalid Signature Rejection
  // ─────────────────────────────────────────────────────────────────────────
  describe("Invalid Signature Rejection", function () {
    it("Should revert when request is signed with the wrong key", async function () {
      const calldata = omniCoin.interface.encodeFunctionData("approve", [
        validator.address,
        ethers.parseEther("100"),
      ]);

      // Sign with validator's key but claim from = user
      const nonce = await forwarder.nonces(user.address);
      const latestBlock = await ethers.provider.getBlock("latest");
      const deadline = BigInt(latestBlock.timestamp) + 3600n;

      const domainData = await forwarder.eip712Domain();
      const eip712Domain = {
        name: domainData.name,
        version: domainData.version,
        chainId: domainData.chainId,
        verifyingContract: domainData.verifyingContract,
      };

      const types = {
        ForwardRequest: [
          { name: "from", type: "address" },
          { name: "to", type: "address" },
          { name: "value", type: "uint256" },
          { name: "gas", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint48" },
          { name: "data", type: "bytes" },
        ],
      };

      const message = {
        from: user.address, // Claims to be user
        to: await omniCoin.getAddress(),
        value: 0n,
        gas: 500000n,
        nonce: nonce,
        deadline: deadline,
        data: calldata,
      };

      // Sign with validator key (wrong signer — should be user)
      const wrongSignature = await validator.signTypedData(
        eip712Domain,
        types,
        message
      );

      const badRequest = {
        from: user.address,
        to: await omniCoin.getAddress(),
        value: 0n,
        gas: 500000n,
        deadline: deadline,
        data: calldata,
        signature: wrongSignature,
      };

      // Verify returns false
      expect(await forwarder.verify(badRequest)).to.be.false;

      // Execute reverts with ERC2771ForwarderInvalidSigner
      await expect(
        forwarder.connect(validator).execute(badRequest)
      ).to.be.revertedWithCustomError(forwarder, "ERC2771ForwarderInvalidSigner");
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 7. Expired Deadline Rejection
  // ─────────────────────────────────────────────────────────────────────────
  describe("Expired Deadline Rejection", function () {
    it("Should revert when deadline has passed", async function () {
      const calldata = omniCoin.interface.encodeFunctionData("approve", [
        validator.address,
        ethers.parseEther("100"),
      ]);

      // Get current block timestamp and create a deadline in the past
      const currentTime = await time.latest();
      const expiredDeadline = BigInt(currentTime) - 100n;

      const request = await buildForwardRequest(
        user,
        forwarder,
        await omniCoin.getAddress(),
        calldata,
        { deadline: expiredDeadline }
      );

      // Verify returns false for expired request
      expect(await forwarder.verify(request)).to.be.false;

      // Execute reverts with ERC2771ForwarderExpiredRequest
      await expect(
        forwarder.connect(validator).execute(request)
      ).to.be.revertedWithCustomError(
        forwarder,
        "ERC2771ForwarderExpiredRequest"
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 8. Wrong Nonce Rejection
  // ─────────────────────────────────────────────────────────────────────────
  describe("Wrong Nonce Rejection", function () {
    it("Should revert when signed with a future nonce", async function () {
      const calldata = omniCoin.interface.encodeFunctionData("approve", [
        validator.address,
        ethers.parseEther("100"),
      ]);

      // Sign with nonce = current + 1 (wrong — should be current)
      const currentNonce = await forwarder.nonces(user.address);
      const request = await buildForwardRequest(
        user,
        forwarder,
        await omniCoin.getAddress(),
        calldata,
        { nonce: currentNonce + 1n }
      );

      // Verify returns false for wrong nonce
      expect(await forwarder.verify(request)).to.be.false;

      // Execute reverts (signer mismatch because nonce is part of signed data)
      await expect(
        forwarder.connect(validator).execute(request)
      ).to.be.revertedWithCustomError(
        forwarder,
        "ERC2771ForwarderInvalidSigner"
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 9. Replay Protection
  // ─────────────────────────────────────────────────────────────────────────
  describe("Replay Protection", function () {
    it("Should prevent replaying a consumed request", async function () {
      const calldata = omniCoin.interface.encodeFunctionData("approve", [
        validator.address,
        ethers.parseEther("100"),
      ]);

      const request = await buildForwardRequest(
        user,
        forwarder,
        await omniCoin.getAddress(),
        calldata
      );

      // First execution succeeds
      await forwarder.connect(validator).execute(request);
      expect(await omniCoin.allowance(user.address, validator.address)).to.equal(
        ethers.parseEther("100")
      );

      // Second execution with the same request must fail (nonce consumed)
      await expect(
        forwarder.connect(validator).execute(request)
      ).to.be.revertedWithCustomError(
        forwarder,
        "ERC2771ForwarderInvalidSigner"
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 10. Nonce Management
  // ─────────────────────────────────────────────────────────────────────────
  describe("Nonce Management", function () {
    it("Should increment nonce after each successful execution", async function () {
      expect(await forwarder.nonces(user.address)).to.equal(0n);

      // First relay
      const calldata1 = omniCoin.interface.encodeFunctionData("approve", [
        validator.address,
        ethers.parseEther("100"),
      ]);
      const req1 = await buildForwardRequest(
        user,
        forwarder,
        await omniCoin.getAddress(),
        calldata1
      );
      await forwarder.connect(validator).execute(req1);
      expect(await forwarder.nonces(user.address)).to.equal(1n);

      // Second relay
      const calldata2 = omniCoin.interface.encodeFunctionData("transfer", [
        recipient1.address,
        ethers.parseEther("50"),
      ]);
      const req2 = await buildForwardRequest(
        user,
        forwarder,
        await omniCoin.getAddress(),
        calldata2
      );
      await forwarder.connect(validator).execute(req2);
      expect(await forwarder.nonces(user.address)).to.equal(2n);

      // Third relay
      const calldata3 = omniCoin.interface.encodeFunctionData("transfer", [
        recipient2.address,
        ethers.parseEther("25"),
      ]);
      const req3 = await buildForwardRequest(
        user,
        forwarder,
        await omniCoin.getAddress(),
        calldata3
      );
      await forwarder.connect(validator).execute(req3);
      expect(await forwarder.nonces(user.address)).to.equal(3n);
    });

    it("Should maintain independent nonces per user", async function () {
      // User executes a relay
      const calldata1 = omniCoin.interface.encodeFunctionData("approve", [
        validator.address,
        ethers.parseEther("100"),
      ]);
      const req1 = await buildForwardRequest(
        user,
        forwarder,
        await omniCoin.getAddress(),
        calldata1
      );
      await forwarder.connect(validator).execute(req1);

      // Owner also executes a relay (independent nonce)
      const calldata2 = omniCoin.interface.encodeFunctionData("approve", [
        validator.address,
        ethers.parseEther("200"),
      ]);
      const req2 = await buildForwardRequest(
        owner,
        forwarder,
        await omniCoin.getAddress(),
        calldata2
      );
      await forwarder.connect(validator).execute(req2);

      // User nonce = 1, owner nonce = 1 (independent)
      expect(await forwarder.nonces(user.address)).to.equal(1n);
      expect(await forwarder.nonces(owner.address)).to.equal(1n);
    });
  });
});
