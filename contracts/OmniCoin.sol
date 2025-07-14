// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./OmniCoinConfig.sol";
import "./OmniCoinReputation.sol";
import "./OmniCoinStaking.sol";
import "./OmniCoinValidator.sol";
import "./OmniCoinMultisig.sol";
import "./OmniCoinPrivacy.sol";
import "./OmniCoinGarbledCircuit.sol";
import "./OmniCoinGovernor.sol";
import "./OmniCoinEscrow.sol";
import "./OmniCoinBridge.sol";

/**
 * @title OmniCoin
 * @dev Implementation of the OmniCoin token with COTI V2 privacy features and integration with all OmniBazaar components
 */
contract OmniCoin is ERC20, AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    OmniCoinConfig public config;
    OmniCoinReputation public reputation;
    OmniCoinStaking public staking;
    OmniCoinValidator public validator;
    OmniCoinMultisig public multisig;
    OmniCoinPrivacy public privacy;
    OmniCoinGarbledCircuit public garbledCircuit;
    OmniCoinGovernor public governor;
    OmniCoinEscrow public escrow;
    OmniCoinBridge public bridge;

    uint256 public multisigThreshold;
    bool public privacyEnabled;

    event MultisigThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event PrivacyToggled(bool enabled);

    constructor(
        address _config,
        address _reputation,
        address _staking,
        address _validator,
        address _multisig,
        address _privacy,
        address _garbledCircuit,
        address _governor,
        address _escrow,
        address _bridge
    ) ERC20("OmniCoin", "OMNI") {
        config = OmniCoinConfig(_config);
        reputation = OmniCoinReputation(_reputation);
        staking = OmniCoinStaking(_staking);
        validator = OmniCoinValidator(_validator);
        multisig = OmniCoinMultisig(_multisig);
        privacy = OmniCoinPrivacy(_privacy);
        garbledCircuit = OmniCoinGarbledCircuit(_garbledCircuit);
        governor = OmniCoinGovernor(_governor);
        escrow = OmniCoinEscrow(_escrow);
        bridge = OmniCoinBridge(_bridge);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);

        multisigThreshold = 1000 * 10 ** 6; // 1000 tokens
        privacyEnabled = true;
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function burn(uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(msg.sender, amount);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function setMultisigThreshold(
        uint256 _threshold
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit MultisigThresholdUpdated(multisigThreshold, _threshold);
        multisigThreshold = _threshold;
    }

    function togglePrivacy() external onlyRole(DEFAULT_ADMIN_ROLE) {
        privacyEnabled = !privacyEnabled;
        emit PrivacyToggled(privacyEnabled);
    }

    function transfer(
        address to,
        uint256 amount
    ) public override whenNotPaused returns (bool) {
        if (amount >= multisigThreshold) {
            require(
                multisig.isApproved(msg.sender, to, amount),
                "OmniCoin: transfer requires multisig approval"
            );
        }
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override whenNotPaused returns (bool) {
        if (amount >= multisigThreshold) {
            require(
                multisig.isApproved(from, to, amount),
                "OmniCoin: transfer requires multisig approval"
            );
        }
        return super.transferFrom(from, to, amount);
    }

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(
            transfer(address(staking), amount),
            "OmniCoin: stake transfer failed"
        );
        staking.stake(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        staking.unstake(msg.sender, amount);
    }

    function claimRewards() external nonReentrant whenNotPaused {
        staking.claimRewards(msg.sender);
    }

    function createEscrow(
        address buyer,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        require(
            transfer(address(escrow), amount),
            "OmniCoin: escrow transfer failed"
        );
        escrow.createEscrow(buyer, address(0), amount, 7 days); // Default 7 days duration, no arbitrator initially
    }

    function releaseEscrow(
        uint256 escrowId
    ) external nonReentrant whenNotPaused {
        escrow.releaseEscrow(escrowId);
    }

    function refundEscrow(
        uint256 escrowId
    ) external nonReentrant whenNotPaused {
        escrow.refundEscrow(escrowId);
    }

    function initiateBridgeTransfer(
        uint256 targetChainId,
        address recipient,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        require(
            transfer(address(bridge), amount),
            "OmniCoin: bridge transfer failed"
        );
        bridge.initiateTransfer(
            targetChainId,
            address(this),
            recipient,
            amount
        ); // Use this contract as target token
    }

    function completeBridgeTransfer(
        uint256 transferId
    ) external nonReentrant whenNotPaused {
        bridge.completeTransfer(transferId, "", ""); // Empty message and signature for now
    }

    function createPrivacyAccount() external nonReentrant whenNotPaused {
        require(privacyEnabled, "OmniCoin: privacy is disabled");
        privacy.createAccount(keccak256(abi.encodePacked(msg.sender))); // Convert address to bytes32 commitment
    }

    function transferPrivate(
        address to,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        require(privacyEnabled, "OmniCoin: privacy is disabled");
        privacy.transfer(
            keccak256(abi.encodePacked(msg.sender)),
            keccak256(abi.encodePacked(to)),
            keccak256(
                abi.encodePacked(msg.sender, to, amount, block.timestamp)
            ), // Generate nullifier
            amount,
            "" // Empty proof for now
        );
    }

    function createCircuit(
        bytes memory circuit
    ) external nonReentrant whenNotPaused {
        garbledCircuit.createCircuit(msg.sender, circuit);
    }

    function evaluateCircuit(
        uint256 circuitId,
        bytes memory input
    ) external nonReentrant whenNotPaused {
        garbledCircuit.evaluateCircuit(circuitId, input);
    }

    function createProposal(
        string memory description
    ) external nonReentrant whenNotPaused {
        // Create empty actions array for simple proposal
        OmniCoinGovernor.ProposalAction[] memory actions;
        governor.propose(description, actions);
    }

    function vote(
        uint256 proposalId,
        bool support
    ) external nonReentrant whenNotPaused {
        // Convert boolean support to VoteType enum (assuming 0=Against, 1=For, 2=Abstain)
        OmniCoinGovernor.VoteType voteType = support
            ? OmniCoinGovernor.VoteType.For
            : OmniCoinGovernor.VoteType.Against;
        governor.castVote(proposalId, voteType);
    }

    function executeProposal(
        uint256 proposalId
    ) external nonReentrant whenNotPaused {
        governor.execute(proposalId);
    }
}
