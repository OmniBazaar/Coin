import { ethers } from "hardhat";

async function main() {
  const userAddress = "0xe89d532934D7771976Ae3530292c9a854ef6449D";
  const registrationAddress = "0x0E4E697317117B150481a827f1e5029864aAe781";
  
  console.log("Unregistering user:", userAddress);
  console.log("From contract:", registrationAddress);
  
  const [deployer] = await ethers.getSigners();
  console.log("Using admin account:", deployer.address);
  
  const OmniRegistration = await ethers.getContractAt("OmniRegistration", registrationAddress);
  
  // Check if user is registered
  const isRegistered = await OmniRegistration.isRegistered(userAddress);
  console.log("Is registered:", isRegistered);
  
  if (!isRegistered) {
    console.log("User is not registered on-chain, nothing to unregister.");
    return;
  }
  
  // Call adminUnregister
  console.log("Calling adminUnregister...");
  const tx = await OmniRegistration.adminUnregister(userAddress);
  console.log("Transaction hash:", tx.hash);
  await tx.wait();
  console.log("User unregistered successfully!");
  
  // Verify
  const isStillRegistered = await OmniRegistration.isRegistered(userAddress);
  console.log("Is still registered:", isStillRegistered);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
