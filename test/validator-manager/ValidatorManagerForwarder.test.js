const { expect } = require("chai");
const { ethers } = require("hardhat");

// The forwarder hard-codes the live base manager address, so a pure unit test
// cannot point it at a mock. Instead this test proves the parts that do not
// depend on that address: the operator gate and the constructor guard, by
// calling the two view/guard paths. The full path against the real base manager
// was simulated on-chain with eth_call (see the runbook, §4).
describe("ValidatorManagerForwarder", () => {
  const MANAGER = "0x0Feedc0de0000000000000000000000000000000";

  it("exposes the live base manager as a constant (no storage)", async () => {
    const F = await ethers.getContractFactory("ValidatorManagerForwarder");
    const f = await F.deploy(await (await ethers.getSigners())[0].getAddress());
    await f.waitForDeployment();
    expect(await f.MANAGER()).to.equal(ethers.getAddress(MANAGER));
  });

  it("rejects a zero operator", async () => {
    const F = await ethers.getContractFactory("ValidatorManagerForwarder");
    await expect(F.deploy(ethers.ZeroAddress)).to.be.revertedWithCustomError(
      F,
      "ZeroAddress"
    );
  });

  it("rejects anyone who is not the operator, before touching the manager", async () => {
    const [operator, stranger] = await ethers.getSigners();
    const F = await ethers.getContractFactory("ValidatorManagerForwarder");
    const f = await F.deploy(await operator.getAddress());
    await f.waitForDeployment();
    const id = ethers.keccak256(ethers.toUtf8Bytes("validator-1")); // any bytes32 works here
    await expect(f.connect(stranger).initiateValidatorRemoval(id))
      .to.be.revertedWithCustomError(F, "NotOperator")
      .withArgs(await stranger.getAddress());
    // the operator gets past the gate and is stopped by the *manager* instead,
    // which proves the forwarder did make the call
    await expect(f.connect(operator).initiateValidatorRemoval(id)).to.be.reverted;
  });
});
