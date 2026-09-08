// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IBridgeVerifier} from "../bridge/IBridgeVerifier.sol";

/**
 * @title MockBridgeVerifier
 * @notice Test-only verifier with operator-settable verify/verifyVeto outcomes.
 * @dev Use to drive bridge unit tests through every branch (valid/invalid proof,
 *      empty attesters, validator-veto succeed/fail, etc.) without depending on
 *      actual ECDSA recovery.
 */
contract MockBridgeVerifier is IBridgeVerifier {
    bool public verifyShouldReturnTrue = true;
    address[] public verifyAttesters;
    bool public verifyVetoShouldReturnTrue = true;
    address public verifyVetoSigner;
    uint256 public quorumThresholdValue = 4;
    mapping(address => bool) public isValidatorMap;

    function setVerify(bool valid, address[] calldata attesters) external {
        verifyShouldReturnTrue = valid;
        delete verifyAttesters;
        for (uint256 i = 0; i < attesters.length; i++) {
            verifyAttesters.push(attesters[i]);
        }
    }

    function setVerifyVeto(bool valid, address signer) external {
        verifyVetoShouldReturnTrue = valid;
        verifyVetoSigner = signer;
    }

    function setQuorumThreshold(uint256 q) external {
        quorumThresholdValue = q;
    }

    function setValidator(address account, bool active) external {
        isValidatorMap[account] = active;
    }

    function verifierVersion() external pure override returns (string memory) {
        return "mock";
    }

    function quorumThreshold() external view override returns (uint256) {
        return quorumThresholdValue;
    }

    function isValidator(address account) external view override returns (bool) {
        return isValidatorMap[account];
    }

    function verify(bytes32, bytes calldata)
        external
        view
        override
        returns (bool, address[] memory)
    {
        return (verifyShouldReturnTrue, verifyAttesters);
    }

    function verifyVeto(bytes32, bytes calldata)
        external
        view
        override
        returns (bool, address)
    {
        return (verifyVetoShouldReturnTrue, verifyVetoSigner);
    }
}
