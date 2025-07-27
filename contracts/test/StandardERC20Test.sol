// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title StandardERC20Test
 * @dev Test contract to verify standard ERC20 works on COTI V2
 * This proves COTI V2 supports regular, non-encrypted tokens
 */
contract StandardERC20Test is ERC20, Ownable {
    
    constructor() ERC20("Test Token", "TEST") Ownable(msg.sender) {
        // Mint 1 million tokens to deployer
        _mint(msg.sender, 1000000 * 10**decimals());
    }
    
    /**
     * @dev Standard public transfer - no encryption
     */
    function transfer(address to, uint256 amount) public override returns (bool) {
        return super.transfer(to, amount);
    }
    
    /**
     * @dev Standard public balanceOf - returns plain uint256
     */
    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account);
    }
    
    /**
     * @dev Mint new tokens (owner only)
     */
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}

/**
 * @title DualModeToken
 * @dev Example of how we could implement dual public/private modes
 */
contract DualModeToken is ERC20, Ownable {
    
    // Events for different transfer types
    event PublicTransfer(address indexed from, address indexed to, uint256 amount);
    event PrivateTransferInitiated(address indexed from, address indexed to, bytes32 commitment);
    
    constructor() ERC20("Dual Mode Token", "DUAL") Ownable(msg.sender) {
        _mint(msg.sender, 1000000 * 10**decimals());
    }
    
    /**
     * @dev Standard public transfer
     */
    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        if (success) {
            emit PublicTransfer(msg.sender, to, amount);
        }
        return success;
    }
    
    /**
     * @dev Initiate a private transfer (would interact with separate PrivateERC20)
     * This is just a placeholder showing the concept
     */
    function initiatePrivateTransfer(
        address to, 
        uint256 amount,
        address privateTokenContract
    ) public returns (bytes32) {
        // Transfer to bridge/escrow
        _transfer(msg.sender, privateTokenContract, amount);
        
        // Create commitment hash (simplified)
        bytes32 commitment = keccak256(abi.encodePacked(msg.sender, to, amount, block.timestamp));
        
        emit PrivateTransferInitiated(msg.sender, to, commitment);
        return commitment;
    }
}