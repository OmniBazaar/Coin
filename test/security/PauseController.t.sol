// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
//
// Foundry test, dependency-free (no forge-std): run it standalone with
//   forge test --match-path test/security/PauseController.t.sol
// It is kept out of the Hardhat suite so the two runners stay independent.
// Ten cases: one-of-five pause, stranger refused, threshold enforced, three
// approvals unpause, revoke, double approval, governance override in both
// directions, non-timelock refused, clear-approvals invalidation, removed
// guardian.

import {PauseController} from "../../contracts/PauseController.sol";

interface Vm {
    function prank(address) external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function expectRevert() external;
    function warp(uint256) external;
}

contract MockTarget {
    bool public paused;
    uint256 public pauseCalls;
    uint256 public unpauseCalls;
    function pause() external { require(!paused, "already"); paused = true; pauseCalls++; }
    function unpause() external { require(paused, "not paused"); paused = false; unpauseCalls++; }
}

contract NoOpTarget {
    bool public paused;
    function pause() external { /* silently does nothing */ }
    function unpause() external { /* silently does nothing */ }
}

contract SplitRoleTarget {
    bool public paused;
    address public immutable pauser;
    address public immutable admin;
    constructor(address pauser_, address admin_) { pauser = pauser_; admin = admin_; }
    function pause() external { require(msg.sender == pauser, "not pauser"); paused = true; }
    function unpause() external { require(msg.sender == admin, "not admin"); paused = false; }
}

contract MockGuardians {
    mapping(address => bool) public isGuardian;
    function set(address a, bool v) external { isGuardian[a] = v; }
}

contract MockTimelock {
    function call(address target, bytes calldata data) external {
        (bool ok, ) = target.call(data);
        require(ok, "call failed");
    }
}

contract PauseControllerTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    PauseController controller;
    MockTarget target;
    MockGuardians guardians;
    MockTimelock timelock;
    address g1 = address(0x1001);
    address g2 = address(0x1002);
    address g3 = address(0x1003);
    address stranger = address(0xBAD);

    function setUp() public {
        timelock = new MockTimelock();
        guardians = new MockGuardians();
        guardians.set(g1, true);
        guardians.set(g2, true);
        guardians.set(g3, true);
        controller = new PauseController(address(timelock), address(guardians));
        target = new MockTarget();
    }

    function testOneGuardianPauses() public {
        vm.prank(g1);
        controller.pause(address(target));
        require(target.paused(), "not paused");
        require(target.pauseCalls() == 1, "wrong count");
    }

    function testStrangerCannotPause() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PauseController.NotGuardian.selector, stranger));
        controller.pause(address(target));
    }

    function testThresholdRequiredToUnpause() public {
        vm.prank(g1); controller.pause(address(target));
        vm.prank(g1); controller.approveUnpause(address(target));
        vm.prank(g2); controller.approveUnpause(address(target));
        vm.expectRevert(abi.encodeWithSelector(PauseController.BelowThreshold.selector, 2, 3));
        controller.executeUnpause(address(target));
        require(target.paused(), "should still be paused");
    }

    function testThreeGuardiansUnpause() public {
        vm.prank(g1); controller.pause(address(target));
        vm.prank(g1); controller.approveUnpause(address(target));
        vm.prank(g2); controller.approveUnpause(address(target));
        vm.prank(g3); controller.approveUnpause(address(target));
        vm.warp(block.timestamp + 1 hours);
        controller.executeUnpause(address(target));
        require(!target.paused(), "not unpaused");
        require(controller.approvalCount(address(target)) == 0, "approvals not cleared");
    }

    function testRevokePreventsUnpause() public {
        vm.prank(g1); controller.pause(address(target));
        vm.prank(g1); controller.approveUnpause(address(target));
        vm.prank(g2); controller.approveUnpause(address(target));
        vm.prank(g3); controller.approveUnpause(address(target));
        vm.prank(g3); controller.revokeUnpause(address(target));
        vm.expectRevert(abi.encodeWithSelector(PauseController.BelowThreshold.selector, 2, 3));
        controller.executeUnpause(address(target));
    }

    function testDoubleApprovalRejected() public {
        vm.prank(g1); controller.pause(address(target));
        vm.prank(g1); controller.approveUnpause(address(target));
        vm.prank(g1);
        vm.expectRevert(PauseController.AlreadyApproved.selector);
        controller.approveUnpause(address(target));
    }

    function testGovernanceOverrides() public {
        vm.prank(g1); controller.pause(address(target));
        vm.prank(address(timelock)); controller.forceUnpause(address(target));
        require(!target.paused(), "governance unpause failed");
        vm.prank(address(timelock)); controller.forcePause(address(target));
        require(target.paused(), "governance pause failed");
    }

    function testNonTimelockCannotForce() public {
        vm.prank(g1);
        vm.expectRevert(abi.encodeWithSelector(PauseController.NotTimelock.selector, g1));
        controller.forceUnpause(address(target));
    }

    function testClearApprovalsInvalidates() public {
        vm.prank(g1); controller.pause(address(target));
        vm.prank(g1); controller.approveUnpause(address(target));
        vm.prank(g2); controller.approveUnpause(address(target));
        vm.prank(g3); controller.approveUnpause(address(target));
        vm.prank(address(timelock)); controller.clearApprovals(address(target));
        vm.expectRevert(abi.encodeWithSelector(PauseController.BelowThreshold.selector, 0, 3));
        controller.executeUnpause(address(target));
        require(!controller.hasApproved(address(target), g1), "stale approval visible");
    }

    function testRemovedGuardianCannotContribute() public {
        vm.prank(g1); controller.pause(address(target));
        vm.prank(g1); controller.approveUnpause(address(target));
        vm.prank(g2); controller.approveUnpause(address(target));
        vm.prank(g3); controller.approveUnpause(address(target));
        guardians.set(g1, false);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(PauseController.BelowThreshold.selector, 2, 3));
        controller.executeUnpause(address(target));
        require(target.paused(), "must stay paused without three current guardians");
    }

    function testStaleApprovalsDoNotSurvivePause() public {
        // Bank three approvals while the target is running.
        vm.prank(g1); controller.approveUnpause(address(target));
        vm.prank(g2); controller.approveUnpause(address(target));
        vm.prank(g3); controller.approveUnpause(address(target));
        // Now pause it for a real incident.
        vm.prank(g1); controller.pause(address(target));
        require(controller.approvalsFor(address(target)) == 0, "banked approvals survived pause");
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(PauseController.BelowThreshold.selector, 0, 3));
        controller.executeUnpause(address(target));
    }

    function testStaleApprovalsDoNotSurviveForceUnpause() public {
        vm.prank(g1); controller.approveUnpause(address(target));
        vm.prank(g2); controller.approveUnpause(address(target));
        vm.prank(g3); controller.approveUnpause(address(target));
        vm.prank(address(timelock)); controller.forcePause(address(target));
        require(controller.approvalsFor(address(target)) == 0, "approvals survived governance pause");
        vm.prank(address(timelock)); controller.forceUnpause(address(target));
        require(!target.paused(), "governance unpause failed");
        vm.expectRevert(abi.encodeWithSelector(PauseController.BelowThreshold.selector, 0, 3));
        controller.executeUnpause(address(target));
    }

    function testChallengeWindowEnforced() public {
        vm.prank(g1); controller.pause(address(target));
        vm.prank(g1); controller.approveUnpause(address(target));
        vm.prank(g2); controller.approveUnpause(address(target));
        vm.prank(g3); controller.approveUnpause(address(target));
        vm.expectRevert();
        controller.executeUnpause(address(target));
        vm.warp(block.timestamp + 1 hours);
        controller.executeUnpause(address(target));
        require(!target.paused(), "not unpaused after the window");
    }

    function testRevokeThenReapproveDoesNotDoubleCount() public {
        vm.prank(g1); controller.pause(address(target));
        vm.prank(g1); controller.approveUnpause(address(target));
        vm.prank(g1); controller.revokeUnpause(address(target));
        vm.prank(g1); controller.approveUnpause(address(target));
        vm.prank(g2); controller.approveUnpause(address(target));
        require(controller.validApprovalsFor(address(target)) == 2, "one guardian counted twice");
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert();
        controller.executeUnpause(address(target));
    }

    function testCodelessTargetRejected() public {
        vm.prank(g1);
        vm.expectRevert(abi.encodeWithSelector(PauseController.NotAContract.selector, stranger));
        controller.pause(stranger);
    }

    function testSilentNoOpTargetRejected() public {
        NoOpTarget noop = new NoOpTarget();
        vm.prank(g1);
        vm.expectRevert(abi.encodeWithSelector(PauseController.TargetStateMismatch.selector, address(noop), false));
        controller.pause(address(noop));
    }

    function testRestartPathDependsOnTargetRoleModel() public {
        // Encoding audit finding M-04: the target only lets its admin unpause.
        SplitRoleTarget split = new SplitRoleTarget(address(controller), address(timelock));
        vm.prank(g1); controller.pause(address(split));
        require(split.paused(), "pause failed");
        vm.prank(address(timelock));
        vm.expectRevert();
        controller.forceUnpause(address(split));
        require(split.paused(), "must stay paused until the role model is fixed");
    }

    function testConstructorRejectsCodelessGuardianSet() public {
        vm.expectRevert(abi.encodeWithSelector(PauseController.NotAContract.selector, stranger));
        new PauseController(address(timelock), stranger);
    }
}
