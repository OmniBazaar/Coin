// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {CommitteeAttestor} from "../attestation/CommitteeAttestor.sol";

/**
 * @title TestCommitteeAttestor
 * @author OmniBazaar Development Team
 * @notice Test-only concrete child of {CommitteeAttestor} that exposes the
 *         internal init/bootstrap/parameter/verify functions so the JS test
 *         suite can exercise them directly. Not for production deploy.
 */
contract TestCommitteeAttestor is CommitteeAttestor {
    /// @notice Bare constructor — initialize via {init} so we can simulate
    ///         deploy-time + post-deploy bootstrap sequences in tests.
    // solhint-disable-next-line no-empty-blocks
    constructor() {}

    /**
     * @notice One-shot test init: set committee parameters.
     * @param committeeSize_ Initial N.
     * @param quorumM_ Initial M.
     */
    function init(uint256 committeeSize_, uint256 quorumM_) external {
        __CommitteeAttestor_init(committeeSize_, quorumM_);
    }

    /**
     * @notice Bootstrap the initial eligible-set. Test-only; in production
     *         this would be wrapped in an admin role check.
     * @param set Sorted-ascending, deduped eligible-set.
     * @param l1Block L1 block at which the source pool was computed.
     * @param sequence Monotonic id; must exceed the current sequence.
     */
    function bootstrapSnapshot(
        address[] calldata set,
        uint256 l1Block,
        uint256 sequence
    ) external {
        address[] memory mem = new address[](set.length);
        for (uint256 i = 0; i < set.length; ++i) mem[i] = set[i];
        _bootstrapSnapshot(mem, l1Block, sequence);
    }

    /**
     * @notice Update committee parameters. Test-only; in production this
     *         would be wrapped in an admin role check.
     * @param newCommitteeSize New N.
     * @param newQuorumM New M.
     */
    function setCommitteeParameters(
        uint256 newCommitteeSize,
        uint256 newQuorumM
    ) external {
        _setCommitteeParameters(newCommitteeSize, newQuorumM);
    }

    /**
     * @notice One-way switch to require pinned commit-blocks. Test-only; in
     *         production this would be wrapped in an admin role check.
     */
    function requireCommitteeSeedPinning() external {
        _requireCommitteeSeedPinning();
    }

    /**
     * @notice External wrapper around `_verifyCommittee` so tests can call it.
     * @param digest The 32-byte message hash signers committed to.
     * @param proof Proof bytes (`commitBlock || sigs concat`).
     * @return valid True if the proof verifies.
     * @return attesters Recovered attester addresses.
     */
    function verifyCommittee(bytes32 digest, bytes calldata proof)
        external
        view
        returns (bool valid, address[] memory attesters)
    {
        return _verifyCommittee(digest, proof);
    }
}
