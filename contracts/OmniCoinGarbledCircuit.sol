// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OmniCoinGarbledCircuit
 * @author OmniCoin Development Team
 * @notice Implements garbled circuit evaluation for privacy-preserving computations
 * @dev Placeholder implementation for future MPC garbled circuit functionality
 */
contract OmniCoinGarbledCircuit is Ownable, ReentrancyGuard {
    struct Circuit {
        bytes circuit;
        bytes inputLabels;
        bytes outputLabels;
        uint256 inputSize;
        uint256 outputSize;
        bool isActive;
    }

    struct Evaluation {
        bytes input;
        bytes output;
        uint256 timestamp;
    }
    
    // Custom errors
    error CircuitTooLarge();
    error CircuitNotActive();
    error InputTooLarge();
    error InvalidInputSize();
    error InvalidMaxCircuitSize();
    error InvalidMaxInputSize();
    error InvalidMaxOutputSize();

    /// @notice Mapping of circuit ID to circuit data
    mapping(uint256 => Circuit) public circuits;
    /// @notice Mapping of circuit ID to evaluation history
    mapping(uint256 => Evaluation[]) public evaluations;

    /// @notice Total number of circuits created
    uint256 public circuitCount;
    /// @notice Maximum allowed circuit size in bytes
    uint256 public maxCircuitSize;
    /// @notice Maximum allowed input size in bytes
    uint256 public maxInputSize;
    /// @notice Maximum allowed output size in bytes
    uint256 public maxOutputSize;

    /**
     * @notice Emitted when a new circuit is created
     * @param circuitId Unique identifier for the circuit
     * @param inputSize Size of circuit input in bytes
     * @param outputSize Size of circuit output in bytes
     */
    event CircuitCreated(
        uint256 indexed circuitId,
        uint256 indexed inputSize,
        uint256 indexed outputSize
    );
    
    /**
     * @notice Emitted when a circuit is deactivated
     * @param circuitId Circuit identifier that was deactivated
     */
    event CircuitDeactivated(uint256 indexed circuitId);
    
    /**
     * @notice Emitted when a circuit is evaluated
     * @param circuitId Circuit identifier that was evaluated
     * @param input Input data for the evaluation
     * @param output Output data from the evaluation
     */
    event CircuitEvaluated(
        uint256 indexed circuitId,
        bytes input,
        bytes output
    );
    
    /**
     * @notice Emitted when maximum circuit size is updated
     * @param oldSize Previous maximum size
     * @param newSize New maximum size
     */
    event MaxCircuitSizeUpdated(uint256 indexed oldSize, uint256 indexed newSize);
    
    /**
     * @notice Emitted when maximum input size is updated
     * @param oldSize Previous maximum size
     * @param newSize New maximum size
     */
    event MaxInputSizeUpdated(uint256 indexed oldSize, uint256 indexed newSize);
    
    /**
     * @notice Emitted when maximum output size is updated
     * @param oldSize Previous maximum size
     * @param newSize New maximum size
     */
    event MaxOutputSizeUpdated(uint256 indexed oldSize, uint256 indexed newSize);

    /**
     * @notice Initialize the garbled circuit contract
     * @param initialOwner Address to be granted ownership
     */
    constructor(address initialOwner) Ownable(initialOwner) {
        maxCircuitSize = 1024 * 1024; // 1MB
        maxInputSize = 1024; // 1KB
        maxOutputSize = 1024; // 1KB
    }

    /**
     * @notice Create a new garbled circuit
     * @param _creator Address creating the circuit (unused in current implementation)
     * @param circuit Circuit data to store
     * @return circuitId Unique identifier for the created circuit
     */
    function createCircuit(
        address /* _creator */,
        bytes calldata circuit
    ) external onlyOwner nonReentrant returns (uint256 circuitId) {
        if (circuit.length > maxCircuitSize) revert CircuitTooLarge();

        circuitId = ++circuitCount;

        // Parse circuit metadata (to be implemented)
        uint256 inputSize = 0;
        uint256 outputSize = 0;
        bytes memory inputLabels;
        bytes memory outputLabels;

        circuits[circuitId] = Circuit({
            circuit: circuit,
            inputLabels: inputLabels,
            outputLabels: outputLabels,
            inputSize: inputSize,
            outputSize: outputSize,
            isActive: true
        });

        emit CircuitCreated(circuitId, inputSize, outputSize);

        return circuitId;
    }

    /**
     * @notice Deactivate an existing circuit
     * @param circuitId Circuit identifier to deactivate
     */
    function deactivateCircuit(uint256 circuitId) external onlyOwner {
        if (!circuits[circuitId].isActive) revert CircuitNotActive();

        circuits[circuitId].isActive = false;

        emit CircuitDeactivated(circuitId);
    }

    /**
     * @notice Evaluate a circuit with given input
     * @param circuitId Circuit identifier to evaluate
     * @param input Input data for the circuit
     */
    function evaluateCircuit(
        uint256 circuitId,
        bytes calldata input
    ) external nonReentrant {
        if (!circuits[circuitId].isActive) revert CircuitNotActive();
        if (input.length > maxInputSize) revert InputTooLarge();
        if (input.length != circuits[circuitId].inputSize) revert InvalidInputSize();

        // Evaluate circuit (to be implemented)
        bytes memory output;

        evaluations[circuitId].push(
            Evaluation({
                input: input,
                output: output,
                timestamp: block.timestamp // solhint-disable-line not-rely-on-time
            })
        );

        emit CircuitEvaluated(circuitId, input, output);
    }

    /**
     * @notice Update maximum allowed circuit size
     * @param _size New maximum circuit size in bytes
     */
    function setMaxCircuitSize(uint256 _size) external onlyOwner {
        emit MaxCircuitSizeUpdated(maxCircuitSize, _size);
        maxCircuitSize = _size;
    }

    /**
     * @notice Update maximum allowed input size
     * @param _size New maximum input size in bytes
     */
    function setMaxInputSize(uint256 _size) external onlyOwner {
        emit MaxInputSizeUpdated(maxInputSize, _size);
        maxInputSize = _size;
    }

    /**
     * @notice Update maximum allowed output size
     * @param _size New maximum output size in bytes
     */
    function setMaxOutputSize(uint256 _size) external onlyOwner {
        emit MaxOutputSizeUpdated(maxOutputSize, _size);
        maxOutputSize = _size;
    }

    /**
     * @notice Get circuit details
     * @param circuitId Circuit identifier to query
     * @return circuit Circuit data
     * @return inputLabels Input label data
     * @return outputLabels Output label data
     * @return inputSize Size of circuit input
     * @return outputSize Size of circuit output
     * @return isActive Whether circuit is active
     */
    function getCircuit(
        uint256 circuitId
    )
        external
        view
        returns (
            bytes memory circuit,
            bytes memory inputLabels,
            bytes memory outputLabels,
            uint256 inputSize,
            uint256 outputSize,
            bool isActive
        )
    {
        Circuit storage c = circuits[circuitId];
        return (
            c.circuit,
            c.inputLabels,
            c.outputLabels,
            c.inputSize,
            c.outputSize,
            c.isActive
        );
    }

    /**
     * @notice Get evaluation details
     * @param circuitId Circuit identifier
     * @param index Evaluation index in the circuit's history
     * @return input Input data used in evaluation
     * @return output Output data from evaluation
     * @return timestamp Time when evaluation occurred
     */
    function getEvaluation(
        uint256 circuitId,
        uint256 index
    )
        external
        view
        returns (bytes memory input, bytes memory output, uint256 timestamp)
    {
        Evaluation storage e = evaluations[circuitId][index];
        return (e.input, e.output, e.timestamp);
    }

    /**
     * @notice Get number of evaluations for a circuit
     * @param circuitId Circuit identifier to query
     * @return count Number of evaluations performed
     */
    function getEvaluationCount(
        uint256 circuitId
    ) external view returns (uint256 count) {
        return evaluations[circuitId].length;
    }
}
