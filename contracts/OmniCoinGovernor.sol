// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesQuorumFractionUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./omnicoin-erc20-coti.sol";
import "./OmniCoinBridge.sol";

/**
 * @title OmniCoinGovernor
 * @dev Governance contract for OmniCoin protocol
 */
contract OmniCoinGovernor is
    Initializable,
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    GovernorVotesQuorumFractionUpgradeable,
    GovernorTimelockControlUpgradeable
{
    OmniCoin public omniCoin;
    OmniCoinBridge public bridge;

    // Proposal types
    enum ProposalType {
        BRIDGE_CONFIG,    // Change bridge parameters
        TOKEN_CONFIG,     // Change token parameters
        PROTOCOL_CONFIG,  // Change protocol parameters
        EMERGENCY        // Emergency actions
    }

    // Events
    event ProposalTypeSet(uint256 proposalId, ProposalType proposalType);
    event BridgeUpdated(address indexed newBridge);
    event EmergencyActionExecuted(address indexed executor, bytes32 indexed actionId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _token,
        address _bridge,
        address _timelock,
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumNumerator
    ) public initializer {
        __Governor_init("OmniCoin Governor");
        __GovernorSettings_init(_votingDelay, _votingPeriod, _proposalThreshold);
        __GovernorCountingSimple_init();
        __GovernorVotes_init(IVotesUpgradeable(_token));
        __GovernorVotesQuorumFraction_init(_quorumNumerator);
        __GovernorTimelockControl_init(ITimelockControllerUpgradeable(_timelock));

        omniCoin = OmniCoin(_token);
        bridge = OmniCoinBridge(_bridge);
    }

    // The following functions are overrides required by Solidity
    function votingDelay()
        public
        view
        override(IGovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.votingDelay();
    }

    function votingPeriod()
        public
        view
        override(IGovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.votingPeriod();
    }

    function quorum(uint256 blockNumber)
        public
        view
        override(IGovernorUpgradeable, GovernorVotesQuorumFractionUpgradeable)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    function state(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        ProposalType proposalType
    ) public override returns (uint256) {
        uint256 proposalId = super.propose(targets, values, calldatas, description);
        emit ProposalTypeSet(proposalId, proposalType);
        return proposalId;
    }

    function _execute(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
        super._execute(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        return super._executor();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @dev Emergency function to pause the protocol
     * Can only be called by the governor
     */
    function emergencyPause() external onlyGovernance {
        omniCoin.pause();
    }

    /**
     * @dev Emergency function to unpause the protocol
     * Can only be called by the governor
     */
    function emergencyUnpause() external onlyGovernance {
        omniCoin.unpause();
    }

    /**
     * @dev Update the bridge contract address
     * Can only be called by the governor
     */
    function updateBridge(address newBridge) external onlyGovernance {
        require(newBridge != address(0), "Invalid bridge address");
        bridge = OmniCoinBridge(newBridge);
        emit BridgeUpdated(newBridge);
    }

    /**
     * @dev Get the proposal type for a given proposal ID
     */
    function getProposalType(uint256 proposalId) external view returns (ProposalType) {
        // This would need to be implemented with a mapping to store proposal types
        revert("Not implemented");
    }
} 