import { ethers } from "hardhat";

async function main(): Promise<void> {
  const lbpAddress = "0xA46CB51fE7b935883577F9Ec15c0D683BCfe49b6";
  const lbp = await ethers.getContractAt("LiquidityBootstrappingPool", lbpAddress);

  console.log("=== LBP Configuration ===");
  console.log("Counter Asset:", await lbp.counterAsset());
  console.log("Counter Asset Decimals:", await lbp.counterAssetDecimals());
  console.log("XOM:", await lbp.xom());
  console.log("Owner:", await lbp.owner());
  console.log("Treasury:", await lbp.treasury());
  console.log("Start Time:", (await lbp.startTime()).toString());
  console.log("End Time:", (await lbp.endTime()).toString());
  console.log("XOM Reserve:", ethers.formatUnits(await lbp.xomReserve(), 18));
  console.log("Counter Asset Reserve:", await lbp.counterAssetReserve());
}

main().catch(console.error);
