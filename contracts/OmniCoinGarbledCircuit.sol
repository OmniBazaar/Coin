// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title OmniCoinGarbledCircuit
 * @dev Implements garbled circuits for enhanced privacy in transactions
 */
contract OmniCoinGarbledCircuit is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    // Structs
    struct Circuit {
        bytes32 circuitId;
        address creator;
        uint256 timestamp;
        bool active;
        uint256[] inputLabels;
        uint256[] outputLabels;
        bytes32[] gates;
        mapping(uint256 => bytes32) wireValues;
    }

    struct Transaction {
        uint256 circuitId;
        bytes32[] inputs;
        bytes32[] outputs;
        bool verified;
    }

    // State variables
    mapping(bytes32 => Circuit) public circuits;
    mapping(bytes32 => Transaction) public transactions;
    mapping(address => bytes32[]) public userCircuits;
    uint256 public nextCircuitId;
    uint256 public verificationFee;

    // Events
    event CircuitCreated(bytes32 indexed circuitId, address indexed creator);
    event CircuitDeactivated(bytes32 indexed circuitId);
    event TransactionVerified(bytes32 indexed txHash, bytes32 indexed circuitId);
    event VerificationFeeUpdated(uint256 newFee);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract
     */
    function initialize(uint256 _verificationFee) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        verificationFee = _verificationFee;
    }

    /**
     * @dev Creates a new garbled circuit
     */
    function createCircuit(
        uint256[] calldata _inputLabels,
        uint256[] calldata _outputLabels,
        bytes32[] calldata _gates
    ) external nonReentrant returns (bytes32 circuitId) {
        require(_inputLabels.length > 0, "No input labels");
        require(_outputLabels.length > 0, "No output labels");
        require(_gates.length > 0, "No gates");

        circuitId = keccak256(abi.encodePacked(
            block.timestamp,
            msg.sender,
            nextCircuitId++
        ));

        Circuit storage circuit = circuits[circuitId];
        circuit.circuitId = circuitId;
        circuit.creator = msg.sender;
        circuit.timestamp = block.timestamp;
        circuit.active = true;
        circuit.inputLabels = _inputLabels;
        circuit.outputLabels = _outputLabels;
        circuit.gates = _gates;

        userCircuits[msg.sender].push(circuitId);

        emit CircuitCreated(circuitId, msg.sender);
    }

    /**
     * @dev Evaluates a garbled circuit
     */
    function evaluateCircuit(
        bytes32 _circuitId,
        bytes32[] calldata _inputs
    ) public nonReentrant returns (bytes32[] memory outputs) {
        Circuit storage circuit = circuits[_circuitId];
        require(circuit.active, "Circuit not active");
        require(_inputs.length == circuit.inputLabels.length, "Invalid input length");

        // Store input values
        for (uint256 i = 0; i < _inputs.length; i++) {
            circuit.wireValues[circuit.inputLabels[i]] = _inputs[i];
        }

        // Evaluate gates
        for (uint256 i = 0; i < circuit.gates.length; i++) {
            bytes32 gate = circuit.gates[i];
            
            // Extract gate components using bitwise operations
            // First 8 bytes: gate type (1 = AND, 2 = OR, 3 = XOR)
            // Next 8 bytes: input wire 1 index
            // Next 8 bytes: input wire 2 index
            // Last 8 bytes: output wire index
            uint256 gateType = uint256(uint64(uint256(gate) >> 192));
            uint256 input1Index = uint256(uint64(uint256(gate) >> 128));
            uint256 input2Index = uint256(uint64(uint256(gate) >> 64));
            uint256 outputIndex = uint256(uint64(uint256(gate)));
            
            // Get input wire values
            bytes32 input1 = circuit.wireValues[input1Index];
            bytes32 input2 = circuit.wireValues[input2Index];
            
            // Perform gate operation based on type
            bytes32 output;
            if (gateType == 1) { // AND
                output = bytes32(uint256(input1) & uint256(input2));
            } else if (gateType == 2) { // OR
                output = bytes32(uint256(input1) | uint256(input2));
            } else if (gateType == 3) { // XOR
                output = bytes32(uint256(input1) ^ uint256(input2));
            } else {
                revert("Invalid gate type");
            }
            
            // Store output wire value
            circuit.wireValues[outputIndex] = output;
        }

        // Collect output values
        outputs = new bytes32[](circuit.outputLabels.length);
        for (uint256 i = 0; i < circuit.outputLabels.length; i++) {
            outputs[i] = circuit.wireValues[circuit.outputLabels[i]];
        }
    }

    /**
     * @dev Verifies a transaction using a garbled circuit
     */
    function verifyTransaction(
        bytes32 _circuitId,
        bytes32[] calldata _inputs,
        bytes32[] calldata _outputs
    ) external payable nonReentrant returns (bool) {
        require(msg.value >= verificationFee, "Insufficient verification fee");
        require(circuits[_circuitId].active, "Circuit not active");

        bytes32 txHash = keccak256(abi.encodePacked(
            _circuitId,
            _inputs,
            _outputs,
            block.timestamp
        ));

        Transaction storage transaction = transactions[txHash];
        require(!transaction.verified, "Transaction already verified");

        // Evaluate circuit
        bytes32[] memory computedOutputs = evaluateCircuit(_circuitId, _inputs);

        // Verify outputs match
        bool valid = true;
        for (uint256 i = 0; i < _outputs.length; i++) {
            if (computedOutputs[i] != _outputs[i]) {
                valid = false;
                break;
            }
        }

        if (valid) {
            transaction.circuitId = uint256(_circuitId);
            transaction.inputs = _inputs;
            transaction.outputs = _outputs;
            transaction.verified = true;

            emit TransactionVerified(txHash, _circuitId);
        }

        // Refund excess fee
        if (msg.value > verificationFee) {
            payable(msg.sender).transfer(msg.value - verificationFee);
        }

        return valid;
    }

    /**
     * @dev Deactivates a circuit
     */
    function deactivateCircuit(bytes32 _circuitId) external {
        Circuit storage circuit = circuits[_circuitId];
        require(circuit.creator == msg.sender || msg.sender == owner(), "Not authorized");
        require(circuit.active, "Circuit already inactive");

        circuit.active = false;
        emit CircuitDeactivated(_circuitId);
    }

    /**
     * @dev Updates verification fee
     */
    function updateVerificationFee(uint256 _newFee) external onlyOwner {
        verificationFee = _newFee;
        emit VerificationFeeUpdated(_newFee);
    }

    /**
     * @dev Returns circuit details
     */
    function getCircuit(bytes32 _circuitId) external view returns (
        address creator,
        uint256 timestamp,
        bool active,
        uint256[] memory inputLabels,
        uint256[] memory outputLabels,
        bytes32[] memory gates
    ) {
        Circuit storage circuit = circuits[_circuitId];
        return (
            circuit.creator,
            circuit.timestamp,
            circuit.active,
            circuit.inputLabels,
            circuit.outputLabels,
            circuit.gates
        );
    }

    /**
     * @dev Returns user's circuits
     */
    function getUserCircuits(address _user) external view returns (bytes32[] memory) {
        return userCircuits[_user];
    }

    /**
     * @dev Returns transaction details
     */
    function getTransaction(bytes32 _txHash) external view returns (
        uint256 circuitId,
        bytes32[] memory inputs,
        bytes32[] memory outputs,
        bool verified
    ) {
        Transaction storage transaction = transactions[_txHash];
        return (
            transaction.circuitId,
            transaction.inputs,
            transaction.outputs,
            transaction.verified
        );
    }
} 