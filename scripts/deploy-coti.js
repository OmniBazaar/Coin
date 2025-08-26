const hre = require("hardhat");

async function main() {
  console.log("Deploying COTI privacy contracts...");
  
  const [deployer] = await hre.ethers.getSigners();
  
  // Deploy Privacy Module
  const PrivacyModule = await hre.ethers.getContractFactory("COTIPrivacyModule");
  const privacyModule = await PrivacyModule.deploy();
  await privacyModule.waitForDeployment();
  console.log("PrivacyModule deployed to:", await privacyModule.getAddress());
  
  // Deploy pXOM Token
  const PXOM = await hre.ethers.getContractFactory("PrivateOmniCoin");
  const pxom = await PXOM.deploy(process.env.OMNICOIN_ADDRESS);
  await pxom.waitForDeployment();
  console.log("pXOM deployed to:", await pxom.getAddress());
  
  return {
    privacyModule: await privacyModule.getAddress(),
    pxom: await pxom.getAddress()
  };
}

main()
  .then((addresses) => {
    console.log(JSON.stringify(addresses));
    process.exit(0);
  })
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
