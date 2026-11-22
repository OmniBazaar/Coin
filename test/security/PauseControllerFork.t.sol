// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
//
// Fork rehearsal against live OmniCoin state. Run from this directory:
//   forge test --fork-url https://rpc.omnicoin.net
// Proves on real contracts, not mocks: one guardian pauses the reward manager,
// three approvals plus the one-hour window restore it, and the treasury stops but
// cannot be restarted because its unpause requires the default admin.

import {PauseController} from "../../contracts/PauseController.sol";

interface Vm {
    function prank(address) external;
    function warp(uint256) external;
    function expectRevert() external;
}

interface IPaused {
    function paused() external view returns (bool);
}

contract ForkRehearsal {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address constant TIMELOCK = 0x4f78386cA05E333639151fe0508b21D893CaD222;
    address constant GUARDIAN = 0xe33c9718767fe77C610Ad4F7DA29dA58Ca0a85Ee;
    address constant REPOINTED_REWARD_MANAGER = 0x3138855f8EdAA2D41f1a2Ae5Cc0C0052b61e9de3;
    address constant TREASURY_V2 = 0x17624a2DCCc71E4c35DA97d633025fE2badD3477;
    address constant POL_MANAGER = 0xBdc9687DF650B8eF5Bc7a9d9a9ABE5A18a6DbAF8;

    address constant MARKETING = 0x824b6b38E7ab95d3Cb6B132481985BAc9BD52683;
    address constant PRESIDENT = 0x062A30E755cC3633EeCd3cDa505725aa50ef222C;
    address constant RICK = 0xEFc0015487b4fF046981bB427553496d14D0873A;

    bytes32 constant PAUSER = keccak256("PAUSER_ROLE");
    bytes32 constant GUARD = keccak256("GUARDIAN_ROLE");

    PauseController controller;

    function setUp() public {
        controller = new PauseController(TIMELOCK, GUARDIAN);
    }

    function grant(address target, bytes32 role, address who) internal {
        vm.prank(TIMELOCK);
        (bool ok, ) = target.call(abi.encodeWithSignature("grantRole(bytes32,address)", role, who));
        require(ok, "grant failed");
    }

    /// Reward manager gates pause AND unpause on the pauser role.
    function testRewardManagerRoundTrip() public {
        grant(REPOINTED_REWARD_MANAGER, PAUSER, address(controller));
        require(!IPaused(REPOINTED_REWARD_MANAGER).paused(), "should start unpaused");

        vm.prank(MARKETING);
        controller.pause(REPOINTED_REWARD_MANAGER);
        require(IPaused(REPOINTED_REWARD_MANAGER).paused(), "pause did not take");

        vm.prank(MARKETING); controller.approveUnpause(REPOINTED_REWARD_MANAGER);
        vm.prank(PRESIDENT); controller.approveUnpause(REPOINTED_REWARD_MANAGER);
        vm.prank(RICK); controller.approveUnpause(REPOINTED_REWARD_MANAGER);
        vm.warp(block.timestamp + 1 hours);
        controller.executeUnpause(REPOINTED_REWARD_MANAGER);
        require(!IPaused(REPOINTED_REWARD_MANAGER).paused(), "unpause did not take");
    }

    /// Treasury V2 gates unpause on DEFAULT_ADMIN, which the controller must not hold.
    function testTreasuryPausesButCannotRestart() public {
        grant(TREASURY_V2, GUARD, address(controller));

        vm.prank(PRESIDENT);
        controller.pause(TREASURY_V2);
        require(IPaused(TREASURY_V2).paused(), "pause did not take");

        vm.prank(MARKETING); controller.approveUnpause(TREASURY_V2);
        vm.prank(PRESIDENT); controller.approveUnpause(TREASURY_V2);
        vm.prank(RICK); controller.approveUnpause(TREASURY_V2);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert();
        controller.executeUnpause(TREASURY_V2);
        require(IPaused(TREASURY_V2).paused(), "must stay paused without the unpause role");
    }

    /// POL manager has the same role split as the treasury.
    function testPolManagerSameSplit() public {
        grant(POL_MANAGER, GUARD, address(controller));
        vm.prank(RICK);
        controller.pause(POL_MANAGER);
        require(IPaused(POL_MANAGER).paused(), "pause did not take");
    }

    /// A non-guardian cannot stop anything on the real contracts.
    function testStrangerCannotPauseOnFork() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        controller.pause(REPOINTED_REWARD_MANAGER);
    }
}
