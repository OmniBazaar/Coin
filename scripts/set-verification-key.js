const { ethers } = require("hardhat");

async function main() {
    const REGISTRATION_ADDRESS = "0x0E4E697317117B150481a827f1e5029864aAe781";
    const VERIFICATION_KEY_ADDRESS = "0xE13a2D66736805Fd57F765E82370C5d7b0FBdE54";
    
    console.log("Setting trustedVerificationKey on OmniRegistration...");
    console.log("Contract:", REGISTRATION_ADDRESS);
    console.log("New Key:", VERIFICATION_KEY_ADDRESS);
    
    const OmniRegistration = await ethers.getContractAt("OmniRegistration", REGISTRATION_ADDRESS);
    
    // Check current key
    const currentKey = await OmniRegistration.trustedVerificationKey();
    console.log("Current Key:", currentKey);
    
    if (currentKey === VERIFICATION_KEY_ADDRESS) {
        console.log("Key already set correctly!");
        return;
    }
    
    // Set the new key
    const tx = await OmniRegistration.setTrustedVerificationKey(VERIFICATION_KEY_ADDRESS);
    console.log("Transaction hash:", tx.hash);
    await tx.wait();
    
    // Verify
    const newKey = await OmniRegistration.trustedVerificationKey();
    console.log("New Key Set:", newKey);
    console.log("Success!");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
