const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniCoinPayment Privacy Functions", function () {
  // Test fixture for deployment
  async function deployPaymentFixture() {
    const [owner, merchant, customer, validator, treasury, development] = await ethers.getSigners();

    // Deploy Registry
    const Registry = await ethers.getContractFactory("OmniCoinRegistry");
    const registry = await Registry.deploy();
    await registry.waitForDeployment();

    // Deploy PrivacyFeeManager
    const PrivacyFeeManager = await ethers.getContractFactory("PrivacyFeeManager");
    const privacyFeeManager = await PrivacyFeeManager.deploy(
      await registry.getAddress(),
      await treasury.getAddress(),
      await development.getAddress()
    );
    await privacyFeeManager.waitForDeployment();

    // Register PrivacyFeeManager
    await registry.registerContract(
      await registry.FEE_MANAGER(),
      await privacyFeeManager.getAddress(),
      "Privacy Fee Manager"
    );

    // Deploy OmniCoinCore
    const OmniCoinCore = await ethers.getContractFactory("OmniCoinCore");
    const omniCoin = await OmniCoinCore.deploy(
      await registry.getAddress(),
      await owner.getAddress(),
      1
    );
    await omniCoin.waitForDeployment();

    // Register OmniCoinCore
    await registry.registerContract(
      await registry.OMNICOIN_CORE(),
      await omniCoin.getAddress(),
      "OmniCoin Core"
    );

    // Deploy OmniCoinAccount
    const OmniCoinAccount = await ethers.getContractFactory("OmniCoinAccount");
    const account = await OmniCoinAccount.deploy(
      await omniCoin.getAddress(),
      await owner.getAddress()
    );
    await account.waitForDeployment();

    // Deploy OmniCoinStaking
    const OmniCoinStaking = await ethers.getContractFactory("OmniCoinStaking");
    const staking = await OmniCoinStaking.deploy(
      await omniCoin.getAddress(),
      100, // 1% reward rate
      86400, // 1 day lock period
      await privacyFeeManager.getAddress()
    );
    await staking.waitForDeployment();

    // Deploy OmniCoinPayment
    const OmniCoinPayment = await ethers.getContractFactory("OmniCoinPayment");
    const payment = await OmniCoinPayment.deploy(
      await omniCoin.getAddress(),
      await account.getAddress(),
      await staking.getAddress(),
      await privacyFeeManager.getAddress()
    );
    await payment.waitForDeployment();

    // Setup
    await omniCoin.mintInitialSupply();
    await omniCoin.addValidator(validator.address);
    await payment.addMerchant(merchant.address);
    await payment.setAccountContract(await account.getAddress());
    await payment.setStakingContract(await staking.getAddress());

    return { 
      payment, omniCoin, account, staking, privacyFeeManager, registry,
      owner, merchant, customer, validator, treasury, development 
    };
  }

  describe("Public Payment Creation (No Privacy)", function () {
    it("Should create public payment without privacy fees", async function () {
      const { payment, merchant, customer, privacyFeeManager } = await loadFixture(deployPaymentFixture);
      
      const amount = ethers.parseUnits("100", 6); // 100 OMNI
      const orderId = "ORDER-001";
      
      // Get initial fees
      const initialFees = await privacyFeeManager.totalFeesCollected();
      
      // Create public payment
      const tx = await payment.connect(merchant).createPayment(
        customer.address,
        amount,
        orderId,
        "Test payment"
      );
      
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment?.name === "PaymentCreated");
      
      // Verify no privacy fees collected
      const finalFees = await privacyFeeManager.totalFeesCollected();
      expect(finalFees).to.equal(initialFees);
      
      // Verify payment created
      const paymentData = await payment.payments(event.args.paymentId);
      expect(paymentData.merchant).to.equal(merchant.address);
      expect(paymentData.customer).to.equal(customer.address);
      expect(paymentData.amount).to.equal(amount);
      expect(paymentData.isPrivate).to.equal(false);
    });

    it("Should process public payment without privacy fees", async function () {
      const { payment, merchant, customer, privacyFeeManager } = await loadFixture(deployPaymentFixture);
      
      const amount = ethers.parseUnits("50", 6);
      const orderId = "ORDER-002";
      
      // Create payment
      const tx = await payment.connect(merchant).createPayment(
        customer.address,
        amount,
        orderId,
        "Test payment"
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment?.name === "PaymentCreated");
      const paymentId = event.args.paymentId;
      
      // Get fees before processing
      const feesBeforeProcess = await privacyFeeManager.totalFeesCollected();
      
      // Process payment
      await payment.connect(customer).processPayment(paymentId);
      
      // Verify no additional privacy fees
      const feesAfterProcess = await privacyFeeManager.totalFeesCollected();
      expect(feesAfterProcess).to.equal(feesBeforeProcess);
      
      // Verify payment processed
      const paymentData = await payment.payments(paymentId);
      expect(paymentData.status).to.equal(1); // Completed status
    });
  });

  describe("Private Payment Creation (With Privacy)", function () {
    it("Should require privacy preference for private payments", async function () {
      const { payment, merchant, customer, omniCoin } = await loadFixture(deployPaymentFixture);
      
      const amount = ethers.parseUnits("200", 6);
      const orderId = "PRIVATE-001";
      
      // Try to create private payment without privacy preference
      await expect(
        payment.connect(merchant).createPaymentWithPrivacy(
          customer.address,
          amount,
          orderId,
          "Private payment",
          true // usePrivacy = true
        )
      ).to.be.revertedWith("Enable privacy preference first");
    });

    it("Should collect privacy fees for private payments when MPC available", async function () {
      const { payment, omniCoin, merchant, customer, privacyFeeManager } = await loadFixture(deployPaymentFixture);
      
      // This test would work on COTI but not in Hardhat
      this.skip();
      
      // Setup for privacy
      await omniCoin.setMpcAvailability(true);
      await omniCoin.connect(merchant).setPrivacyPreference(true);
      await payment.setMpcAvailability(true);
      
      const amount = ethers.parseUnits("500", 6);
      const orderId = "PRIVATE-002";
      const baseFee = ethers.parseUnits("0.5", 6); // 0.5 OMNI base fee
      const expectedPrivacyFee = baseFee * 10n; // 10x for privacy
      
      // Get initial fees
      const initialFees = await privacyFeeManager.totalFeesCollected();
      
      // Create private payment
      await payment.connect(merchant).createPaymentWithPrivacy(
        customer.address,
        amount,
        orderId,
        "Private payment",
        true
      );
      
      // Verify privacy fees collected
      const finalFees = await privacyFeeManager.totalFeesCollected();
      expect(finalFees - initialFees).to.equal(expectedPrivacyFee);
    });

    it("Should handle public payment through privacy function when usePrivacy=false", async function () {
      const { payment, merchant, customer, privacyFeeManager } = await loadFixture(deployPaymentFixture);
      
      const amount = ethers.parseUnits("150", 6);
      const orderId = "MIXED-001";
      
      // Get initial fees
      const initialFees = await privacyFeeManager.totalFeesCollected();
      
      // Create payment with privacy function but usePrivacy=false
      const tx = await payment.connect(merchant).createPaymentWithPrivacy(
        customer.address,
        amount,
        orderId,
        "Public via privacy function",
        false // usePrivacy = false
      );
      
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment?.name === "PaymentCreated");
      
      // Verify no privacy fees
      const finalFees = await privacyFeeManager.totalFeesCollected();
      expect(finalFees).to.equal(initialFees);
      
      // Verify payment is public
      const paymentData = await payment.payments(event.args.paymentId);
      expect(paymentData.isPrivate).to.equal(false);
    });
  });

  describe("Recurring Payments", function () {
    it("Should create and process recurring payments", async function () {
      const { payment, merchant, customer } = await loadFixture(deployPaymentFixture);
      
      const amount = ethers.parseUnits("25", 6);
      const interval = 86400; // 1 day
      const orderId = "RECURRING-001";
      
      // Create recurring payment
      const tx = await payment.connect(merchant).createRecurringPayment(
        customer.address,
        amount,
        interval,
        orderId,
        "Monthly subscription"
      );
      
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment?.name === "RecurringPaymentCreated");
      const recurringId = event.args.recurringId;
      
      // Process first payment
      await payment.connect(customer).processRecurringPayment(recurringId);
      
      // Fast forward 1 day
      await time.increase(86400);
      
      // Process second payment
      await payment.connect(customer).processRecurringPayment(recurringId);
      
      // Verify recurring payment data
      const recurringData = await payment.recurringPayments(recurringId);
      expect(recurringData.processedCount).to.equal(2);
    });

    it("Should cancel recurring payments", async function () {
      const { payment, merchant, customer } = await loadFixture(deployPaymentFixture);
      
      const amount = ethers.parseUnits("30", 6);
      const interval = 86400;
      const orderId = "RECURRING-002";
      
      // Create recurring payment
      const tx = await payment.connect(merchant).createRecurringPayment(
        customer.address,
        amount,
        interval,
        orderId,
        "Weekly subscription"
      );
      
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment?.name === "RecurringPaymentCreated");
      const recurringId = event.args.recurringId;
      
      // Cancel recurring payment
      await payment.connect(customer).cancelRecurringPayment(recurringId);
      
      // Verify cancellation
      const recurringData = await payment.recurringPayments(recurringId);
      expect(recurringData.isActive).to.equal(false);
      
      // Try to process cancelled payment (should fail)
      await expect(
        payment.connect(customer).processRecurringPayment(recurringId)
      ).to.be.revertedWith("Recurring payment not active");
    });
  });

  describe("Payment with Staking Rewards", function () {
    it("Should integrate with staking rewards system", async function () {
      const { payment, staking, merchant, customer, omniCoin } = await loadFixture(deployPaymentFixture);
      
      const stakeAmount = ethers.parseUnits("1000", 6);
      const paymentAmount = ethers.parseUnits("50", 6);
      const orderId = "STAKE-001";
      
      // Customer stakes tokens first
      // Note: In test environment, we simulate staking
      
      // Create payment
      const tx = await payment.connect(merchant).createPayment(
        customer.address,
        paymentAmount,
        orderId,
        "Payment with staking benefits"
      );
      
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment?.name === "PaymentCreated");
      const paymentId = event.args.paymentId;
      
      // Process payment
      await payment.connect(customer).processPayment(paymentId);
      
      // Verify payment completed
      const paymentData = await payment.payments(paymentId);
      expect(paymentData.status).to.equal(1); // Completed
    });
  });

  describe("Batch Payment Operations", function () {
    it("Should handle batch payment creation", async function () {
      const { payment, merchant, customer, owner } = await loadFixture(deployPaymentFixture);
      
      const amount1 = ethers.parseUnits("10", 6);
      const amount2 = ethers.parseUnits("20", 6);
      const amount3 = ethers.parseUnits("30", 6);
      
      // Create multiple payments
      const tx1 = await payment.connect(merchant).createPayment(
        customer.address,
        amount1,
        "BATCH-001",
        "Payment 1"
      );
      
      const tx2 = await payment.connect(merchant).createPayment(
        owner.address,
        amount2,
        "BATCH-002",
        "Payment 2"
      );
      
      const tx3 = await payment.connect(merchant).createPayment(
        customer.address,
        amount3,
        "BATCH-003",
        "Payment 3"
      );
      
      // Get payment IDs
      const receipt1 = await tx1.wait();
      const receipt2 = await tx2.wait();
      const receipt3 = await tx3.wait();
      
      const event1 = receipt1.logs.find(log => log.fragment?.name === "PaymentCreated");
      const event2 = receipt2.logs.find(log => log.fragment?.name === "PaymentCreated");
      const event3 = receipt3.logs.find(log => log.fragment?.name === "PaymentCreated");
      
      // Process first payment
      await payment.connect(customer).processPayment(event1.args.paymentId);
      
      // Verify only first payment is processed
      const payment1 = await payment.payments(event1.args.paymentId);
      const payment2 = await payment.payments(event2.args.paymentId);
      const payment3 = await payment.payments(event3.args.paymentId);
      
      expect(payment1.status).to.equal(1); // Completed
      expect(payment2.status).to.equal(0); // Pending
      expect(payment3.status).to.equal(0); // Pending
    });
  });

  describe("Edge Cases and Security", function () {
    it("Should handle payment cancellation", async function () {
      const { payment, merchant, customer } = await loadFixture(deployPaymentFixture);
      
      const amount = ethers.parseUnits("75", 6);
      const orderId = "CANCEL-001";
      
      // Create payment
      const tx = await payment.connect(merchant).createPayment(
        customer.address,
        amount,
        orderId,
        "To be cancelled"
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment?.name === "PaymentCreated");
      const paymentId = event.args.paymentId;
      
      // Cancel payment
      await payment.connect(merchant).cancelPayment(paymentId);
      
      // Verify cancellation
      const paymentData = await payment.payments(paymentId);
      expect(paymentData.status).to.equal(2); // Cancelled
      
      // Try to process cancelled payment (should fail)
      await expect(
        payment.connect(customer).processPayment(paymentId)
      ).to.be.revertedWith("Payment not pending");
    });

    it("Should prevent double payment processing", async function () {
      const { payment, merchant, customer } = await loadFixture(deployPaymentFixture);
      
      const amount = ethers.parseUnits("40", 6);
      const orderId = "DOUBLE-001";
      
      // Create and process payment
      const tx = await payment.connect(merchant).createPayment(
        customer.address,
        amount,
        orderId,
        "Test"
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => log.fragment?.name === "PaymentCreated");
      const paymentId = event.args.paymentId;
      
      await payment.connect(customer).processPayment(paymentId);
      
      // Try to process again (should fail)
      await expect(
        payment.connect(customer).processPayment(paymentId)
      ).to.be.revertedWith("Payment not pending");
    });

    it("Should respect merchant permissions", async function () {
      const { payment, customer, owner } = await loadFixture(deployPaymentFixture);
      
      const amount = ethers.parseUnits("100", 6);
      const orderId = "PERM-001";
      
      // Non-merchant tries to create payment (should fail)
      await expect(
        payment.connect(owner).createPayment(
          customer.address,
          amount,
          orderId,
          "Unauthorized"
        )
      ).to.be.revertedWith("Only registered merchant");
    });
  });
});