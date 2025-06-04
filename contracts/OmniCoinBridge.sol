// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@layerzerolabs/solidity-examples/contracts/lzApp/NonblockingLzApp.sol";
import "./omnicoin-erc20-coti.sol";

/**
 * @title OmniCoinBridge
 * @dev Handles cross-chain token transfers using LayerZero
 */
contract OmniCoinBridge is NonblockingLzApp, ReentrancyGuard {
    OmniCoin public immutable omniCoin;
    
    // Mapping of chain IDs to trusted remote addresses
    mapping(uint16 => bytes) public override trustedRemoteLookup;
    
    // Events
    event BridgeInitiated(address indexed from, uint16 indexed dstChainId, uint256 amount);
    event BridgeReceived(address indexed to, uint16 indexed srcChainId, uint256 amount);
    event TrustedRemoteSet(uint16 indexed chainId, bytes remoteAddress);
    
    constructor(
        address _endpoint,
        address _omniCoin
    ) NonblockingLzApp(_endpoint) {
        omniCoin = OmniCoin(_omniCoin);
    }
    
    /**
     * @dev Bridge tokens to another chain
     * @param _dstChainId The destination chain ID
     * @param _amount The amount of tokens to bridge
     * @param _dstAddress The destination address
     */
    function bridgeTokens(
        uint16 _dstChainId,
        uint256 _amount,
        bytes calldata _dstAddress
    ) external payable nonReentrant {
        require(trustedRemoteLookup[_dstChainId].length > 0, "Destination chain not trusted");
        require(_amount > 0, "Amount must be greater than 0");
        
        // Transfer tokens from user to this contract
        require(omniCoin.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        // Prepare the payload
        bytes memory payload = abi.encode(msg.sender, _amount);
        
        // Send the message
        _lzSend(
            _dstChainId,
            payload,
            payable(msg.sender),
            address(0x0),
            bytes(""),
            msg.value
        );
        
        emit BridgeInitiated(msg.sender, _dstChainId, _amount);
    }
    
    /**
     * @dev Receive bridged tokens from another chain
     * @param _srcChainId The source chain ID
     * @param _srcAddress The source address
     * @param _nonce The nonce
     * @param _payload The payload containing the recipient and amount
     */
    function _nonblockingLzReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload
    ) internal override {
        require(trustedRemoteLookup[_srcChainId].length > 0, "Source chain not trusted");
        
        // Decode the payload
        (address recipient, uint256 amount) = abi.decode(_payload, (address, uint256));
        
        // Transfer tokens to the recipient
        require(omniCoin.transfer(recipient, amount), "Transfer failed");
        
        emit BridgeReceived(recipient, _srcChainId, amount);
    }
    
    /**
     * @dev Set a trusted remote address for a chain
     * @param _chainId The chain ID
     * @param _remoteAddress The remote address
     */
    function setTrustedRemote(uint16 _chainId, bytes calldata _remoteAddress) external override onlyOwner {
        trustedRemoteLookup[_chainId] = _remoteAddress;
        emit TrustedRemoteSet(_chainId, _remoteAddress);
    }
    
    /**
     * @dev Estimate the fee for bridging tokens
     * @param _dstChainId The destination chain ID
     * @param _amount The amount of tokens to bridge
     * @param _dstAddress The destination address
     */
    function estimateBridgeFee(
        uint16 _dstChainId,
        uint256 _amount,
        bytes calldata _dstAddress
    ) external view returns (uint256 nativeFee, uint256 zroFee) {
        bytes memory payload = abi.encode(msg.sender, _amount);
        return lzEndpoint.estimateFees(
            _dstChainId,
            address(this),
            payload,
            false,
            bytes("")
        );
    }
} 