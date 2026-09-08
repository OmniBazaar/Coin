/**
 * Shared test helper for deploying + linking `CommitteeAttestorLib`.
 *
 * Every contract inheriting {CommitteeAttestor} now DELEGATECALL-links the
 * external `CommitteeAttestorLib` (the VT-27 EIP-170 full base extraction),
 * so any test fixture that deploys such a contract must link the library
 * address at factory time — exactly like the live `deploy-vt27-coti.ts`.
 *
 * Deploys the library once per process and caches the address; cheap to call
 * repeatedly.
 */
const { ethers } = require("hardhat");

let cachedAddress = null;

/** Deploy (once) and return the `CommitteeAttestorLib` address. */
async function deployCommitteeAttestorLib() {
    if (cachedAddress === null) {
        const Lib = await ethers.getContractFactory("CommitteeAttestorLib");
        const lib = await Lib.deploy();
        await lib.waitForDeployment();
        cachedAddress = await lib.getAddress();
    }
    return cachedAddress;
}

/**
 * Return the `libraries` object to pass to `getContractFactory`, with
 * `CommitteeAttestorLib` linked and any caller-supplied extras merged in
 * (e.g. `PrivatePredictionMath` for PrivatePredictionMarket).
 */
async function committeeAttestorLibraries(extra) {
    const addr = await deployCommitteeAttestorLib();
    return { ...(extra || {}), CommitteeAttestorLib: addr };
}

module.exports = { deployCommitteeAttestorLib, committeeAttestorLibraries };
