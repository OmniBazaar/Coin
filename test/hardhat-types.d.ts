/**
 * @file hardhat-types.d.ts
 * @description Type augmentation imports for the Coin module test suite.
 *
 * Explicitly references the Hardhat plugin type extensions so that TypeScript
 * picks up the `HardhatRuntimeEnvironment.ethers` property (from
 * `@nomicfoundation/hardhat-ethers`) and the chai matchers extension methods
 * (`emit`, `revertedWith`, `revertedWithCustomError`, etc.) provided by
 * `@nomicfoundation/hardhat-chai-matchers`.
 *
 * These augmentations are activated via module-declaration merging in the
 * plugin packages. Importing the index declaration files here causes TypeScript
 * to process those merges for all test files in the compilation unit.
 */

// Extends HardhatRuntimeEnvironment with `ethers` and `upgrades` helpers.
import "@nomicfoundation/hardhat-ethers";
import "@openzeppelin/hardhat-upgrades";

// Extends the Chai `Assertion` interface with `.emit()`, `.reverted`,
// `.revertedWith()`, `.revertedWithCustomError()`, etc.
import "@nomicfoundation/hardhat-chai-matchers";
