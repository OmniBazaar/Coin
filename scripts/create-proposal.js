const { ethers } = require("hardhat");

async function main() {
  const [proposer] = await ethers.getSigners();
  console.log("Creating proposal with account:", proposer.address);

  // Get contract addresses from environment
  const governorAddress = process.env.GOVERNOR_ADDRESS;
  const tokenAddress = process.env.TOKEN_ADDRESS;

  if (!governorAddress || !tokenAddress) {
    throw new Error("GOVERNOR_ADDRESS and TOKEN_ADDRESS must be set in environment variables");
  }

  // Get contract instances
  const governor = await ethers.getContractAt("OmniCoinGovernor", governorAddress);
  const token = await ethers.getContractAt("OmniCoin", tokenAddress);

  // Check if proposer has enough tokens
  const balance = await token.balanceOf(proposer.address);
  const proposalThreshold = await governor.proposalThreshold();
  
  if (balance.lt(proposalThreshold)) {
    throw new Error(`Insufficient balance. Required: ${ethers.utils.formatEther(proposalThreshold)} tokens`);
  }

  // Example proposal: Update bridge parameters
  const targets = [process.env.BRIDGE_ADDRESS];
  const values = [0];
  const calldatas = [
    ethers.utils.defaultAbiCoder.encode(
      ["uint16", "bytes"],
      [1, ethers.utils.defaultAbiCoder.encode(["address"], ["0x..."])] // Example parameters
    )
  ];
  const description = "Update bridge parameters for chain ID 1";

  // Create proposal
  const tx = await governor.propose(
    targets,
    values,
    calldatas,
    description,
    0 // ProposalType.BRIDGE_CONFIG
  );
  
  const receipt = await tx.wait();
  const proposalId = receipt.events.find(e => e.event === "ProposalCreated").args.proposalId;
  
  console.log("\nProposal created successfully!");
  console.log("Proposal ID:", proposalId);
  console.log("Description:", description);
  console.log("\nNext steps:");
  console.log("1. Wait for voting delay to end");
  console.log("2. Cast votes using castVote()");
  console.log("3. Wait for voting period to end");
  console.log("4. Queue proposal using queue()");
  console.log("5. Execute proposal using execute()");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 