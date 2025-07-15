// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OmniCoinBridge is Ownable, ReentrancyGuard {
    struct BridgeConfig {
        uint256 chainId;
        address token;
        bool isActive;
        uint256 minAmount;
        uint256 maxAmount;
        uint256 fee;
    }

    struct Transfer {
        uint256 id;
        address sender;
        uint256 sourceChainId;
        uint256 targetChainId;
        address targetToken;
        address recipient;
        uint256 amount;
        uint256 fee;
        uint256 timestamp;
        bool completed;
        bool refunded;
    }

    IERC20 public token;

    mapping(uint256 => BridgeConfig) public bridgeConfigs;
    mapping(uint256 => Transfer) public transfers;
    mapping(bytes32 => bool) public processedMessages;

    uint256 public transferCount;
    uint256 public minTransferAmount;
    uint256 public maxTransferAmount;
    uint256 public baseFee;
    uint256 public messageTimeout;

    event BridgeConfigured(
        uint256 indexed chainId,
        address indexed token,
        uint256 minAmount,
        uint256 maxAmount,
        uint256 fee
    );
    event TransferInitiated(
        uint256 indexed transferId,
        address indexed sender,
        uint256 sourceChainId,
        uint256 targetChainId,
        address targetToken,
        address recipient,
        uint256 amount,
        uint256 fee
    );
    event TransferCompleted(
        uint256 indexed transferId,
        address indexed recipient,
        uint256 amount
    );
    event TransferRefunded(
        uint256 indexed transferId,
        address indexed sender,
        uint256 amount,
        uint256 fee
    );
    event MinTransferAmountUpdated(uint256 newAmount);
    event MaxTransferAmountUpdated(uint256 newAmount);
    event BaseFeeUpdated(uint256 newFee);
    event MessageTimeoutUpdated(uint256 newTimeout);

    constructor(address _token, address initialOwner) Ownable(initialOwner) {
        token = IERC20(_token);
        minTransferAmount = 100 * 10 ** 6; // 100 tokens
        maxTransferAmount = 1000000 * 10 ** 6; // 1M tokens
        baseFee = 1 * 10 ** 6; // 1 token
        messageTimeout = 1 hours;
    }

    function configureBridge(
        uint256 _chainId,
        address _token,
        uint256 _minAmount,
        uint256 _maxAmount,
        uint256 _fee
    ) external onlyOwner {
        require(_token != address(0), "Invalid token");
        require(_minAmount > 0, "Invalid min amount");
        require(_maxAmount > _minAmount, "Invalid max amount");
        require(_fee >= baseFee, "Invalid fee");

        bridgeConfigs[_chainId] = BridgeConfig({
            chainId: _chainId,
            token: _token,
            isActive: true,
            minAmount: _minAmount,
            maxAmount: _maxAmount,
            fee: _fee
        });

        emit BridgeConfigured(_chainId, _token, _minAmount, _maxAmount, _fee);
    }

    function initiateTransfer(
        uint256 _targetChainId,
        address _targetToken,
        address _recipient,
        uint256 _amount
    ) external nonReentrant {
        BridgeConfig storage config = bridgeConfigs[_targetChainId];
        require(config.isActive, "Bridge inactive");
        require(_amount >= config.minAmount, "Amount too small");
        require(_amount <= config.maxAmount, "Amount too large");

        uint256 transferId = transferCount++;
        uint256 fee = config.fee;

        transfers[transferId] = Transfer({
            id: transferId,
            sender: msg.sender,
            sourceChainId: block.chainid,
            targetChainId: _targetChainId,
            targetToken: _targetToken,
            recipient: _recipient,
            amount: _amount,
            fee: fee,
            timestamp: block.timestamp,
            completed: false,
            refunded: false
        });

        require(
            token.transferFrom(msg.sender, address(this), _amount + fee),
            "Transfer failed"
        );

        emit TransferInitiated(
            transferId,
            msg.sender,
            block.chainid,
            _targetChainId,
            _targetToken,
            _recipient,
            _amount,
            fee
        );
    }

    function completeTransfer(
        uint256 _transferId,
        bytes memory _message,
        bytes memory _signature
    ) external nonReentrant {
        Transfer storage transfer = transfers[_transferId];
        require(!transfer.completed, "Already completed");
        require(!transfer.refunded, "Already refunded");
        require(
            block.timestamp <= transfer.timestamp + messageTimeout,
            "Message expired"
        );

        bytes32 messageHash = keccak256(
            abi.encodePacked(
                _transferId,
                transfer.sender,
                transfer.sourceChainId,
                transfer.targetChainId,
                transfer.targetToken,
                transfer.recipient,
                transfer.amount,
                transfer.fee
            )
        );

        require(!processedMessages[messageHash], "Message processed");
        require(verifyMessage(messageHash, _signature), "Invalid signature");

        transfer.completed = true;
        processedMessages[messageHash] = true;

        require(
            token.transfer(transfer.recipient, transfer.amount),
            "Transfer failed"
        );

        emit TransferCompleted(
            _transferId,
            transfer.recipient,
            transfer.amount
        );
    }

    function refundTransfer(uint256 _transferId) external nonReentrant {
        Transfer storage transfer = transfers[_transferId];
        require(!transfer.completed, "Already completed");
        require(!transfer.refunded, "Already refunded");
        require(
            block.timestamp > transfer.timestamp + messageTimeout,
            "Not expired"
        );

        transfer.refunded = true;

        require(
            token.transfer(transfer.sender, transfer.amount + transfer.fee),
            "Transfer failed"
        );

        emit TransferRefunded(
            _transferId,
            transfer.sender,
            transfer.amount,
            transfer.fee
        );
    }

    function setMinTransferAmount(uint256 _amount) external onlyOwner {
        require(_amount > 0, "Invalid amount");
        minTransferAmount = _amount;
        emit MinTransferAmountUpdated(_amount);
    }

    function setMaxTransferAmount(uint256 _amount) external onlyOwner {
        require(_amount > minTransferAmount, "Invalid amount");
        maxTransferAmount = _amount;
        emit MaxTransferAmountUpdated(_amount);
    }

    function setBaseFee(uint256 _fee) external onlyOwner {
        require(_fee > 0, "Invalid fee");
        baseFee = _fee;
        emit BaseFeeUpdated(_fee);
    }

    function setMessageTimeout(uint256 _timeout) external onlyOwner {
        require(_timeout > 0, "Invalid timeout");
        messageTimeout = _timeout;
        emit MessageTimeoutUpdated(_timeout);
    }

    function getTransfer(
        uint256 _transferId
    )
        external
        view
        returns (
            address sender,
            uint256 sourceChainId,
            uint256 targetChainId,
            address targetToken,
            address recipient,
            uint256 amount,
            uint256 fee,
            uint256 timestamp,
            bool completed,
            bool refunded
        )
    {
        Transfer storage transfer = transfers[_transferId];
        return (
            transfer.sender,
            transfer.sourceChainId,
            transfer.targetChainId,
            transfer.targetToken,
            transfer.recipient,
            transfer.amount,
            transfer.fee,
            transfer.timestamp,
            transfer.completed,
            transfer.refunded
        );
    }

    function getBridgeConfig(
        uint256 _chainId
    )
        external
        view
        returns (
            address token,
            bool isActive,
            uint256 minAmount,
            uint256 maxAmount,
            uint256 fee
        )
    {
        BridgeConfig storage config = bridgeConfigs[_chainId];
        return (
            config.token,
            config.isActive,
            config.minAmount,
            config.maxAmount,
            config.fee
        );
    }

    function verifyMessage(
        bytes32 _messageHash,
        bytes memory _signature
    ) internal view returns (bool) {
        // TODO: Implement message verification
        // This is a placeholder that should be replaced with actual verification
        return true;
    }
}
