// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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

    mapping(uint256 => Circuit) public circuits;
    mapping(uint256 => Evaluation[]) public evaluations;

    uint256 public circuitCount;
    uint256 public maxCircuitSize;
    uint256 public maxInputSize;
    uint256 public maxOutputSize;

    event CircuitCreated(
        uint256 indexed circuitId,
        uint256 inputSize,
        uint256 outputSize
    );
    event CircuitDeactivated(uint256 indexed circuitId);
    event CircuitEvaluated(
        uint256 indexed circuitId,
        bytes input,
        bytes output
    );
    event MaxCircuitSizeUpdated(uint256 oldSize, uint256 newSize);
    event MaxInputSizeUpdated(uint256 oldSize, uint256 newSize);
    event MaxOutputSizeUpdated(uint256 oldSize, uint256 newSize);

    constructor(address initialOwner) Ownable(initialOwner) {
        maxCircuitSize = 1024 * 1024; // 1MB
        maxInputSize = 1024; // 1KB
        maxOutputSize = 1024; // 1KB
    }

    function createCircuit(
        address owner,
        bytes memory circuit
    ) external onlyOwner nonReentrant returns (uint256) {
        require(
            circuit.length <= maxCircuitSize,
            "OmniCoinGarbledCircuit: circuit too large"
        );

        uint256 circuitId = circuitCount++;

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

    function deactivateCircuit(uint256 circuitId) external onlyOwner {
        require(
            circuits[circuitId].isActive,
            "OmniCoinGarbledCircuit: circuit not active"
        );

        circuits[circuitId].isActive = false;

        emit CircuitDeactivated(circuitId);
    }

    function evaluateCircuit(
        uint256 circuitId,
        bytes memory input
    ) external nonReentrant {
        require(
            circuits[circuitId].isActive,
            "OmniCoinGarbledCircuit: circuit not active"
        );
        require(
            input.length <= maxInputSize,
            "OmniCoinGarbledCircuit: input too large"
        );
        require(
            input.length == circuits[circuitId].inputSize,
            "OmniCoinGarbledCircuit: invalid input size"
        );

        // Evaluate circuit (to be implemented)
        bytes memory output;

        evaluations[circuitId].push(
            Evaluation({
                input: input,
                output: output,
                timestamp: block.timestamp
            })
        );

        emit CircuitEvaluated(circuitId, input, output);
    }

    function setMaxCircuitSize(uint256 _size) external onlyOwner {
        emit MaxCircuitSizeUpdated(maxCircuitSize, _size);
        maxCircuitSize = _size;
    }

    function setMaxInputSize(uint256 _size) external onlyOwner {
        emit MaxInputSizeUpdated(maxInputSize, _size);
        maxInputSize = _size;
    }

    function setMaxOutputSize(uint256 _size) external onlyOwner {
        emit MaxOutputSizeUpdated(maxOutputSize, _size);
        maxOutputSize = _size;
    }

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

    function getEvaluationCount(
        uint256 circuitId
    ) external view returns (uint256) {
        return evaluations[circuitId].length;
    }
}
