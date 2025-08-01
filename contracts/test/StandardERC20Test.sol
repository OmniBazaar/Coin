// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title StandardERC20Test
 * @author OmniCoin Development Team
 * @notice Test contract to verify standard ERC20 functionality on COTI V2
 * @dev This proves COTI V2 supports regular, non-encrypted tokens alongside private ones.
 *      Used for testing compatibility with existing ERC20 infrastructure.
 */
contract StandardERC20Test is ERC20, Ownable {
    
    /**
     * @notice Initialize the test token with initial supply
     * @dev Mints 1 million tokens to the deployer for testing
     */
    constructor() ERC20("Test Token", "TEST") Ownable(msg.sender) {
        // Mint 1 million tokens to deployer
        _mint(msg.sender, 1000000 * 10**decimals());
    }
    
    /**
     * @notice Standard public transfer function - no encryption
     * @dev Overrides ERC20 transfer to demonstrate public transfer functionality
     * @param to The recipient address
     * @param amount The amount to transfer
     * @return success Whether the transfer succeeded
     */
    function transfer(address to, uint256 amount) public override returns (bool success) {
        return super.transfer(to, amount);
    }
    
    /**
     * @notice Mint new tokens (owner only)
     * @dev Allows the owner to mint additional tokens for testing
     * @param to The recipient address for newly minted tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice Standard public balanceOf function - returns plain uint256
     * @dev Overrides ERC20 balanceOf to demonstrate public balance queries
     * @param account The account to check balance for
     * @return balance The account's token balance
     */
    function balanceOf(address account) public view override returns (uint256 balance) {
        return super.balanceOf(account);
    }
}

/**
 * @title DualModeToken
 * @author OmniCoin Development Team
 * @notice Example token supporting both public and private transfer modes
 * @dev Demonstrates how to implement dual public/private transfer functionality.
 *      This is a conceptual example showing integration patterns between public and private tokens.
 */
contract DualModeToken is ERC20, Ownable {
    
    // Events for different transfer types
    /// @notice Emitted when a public transfer occurs
    /// @param from The sender address
    /// @param to The recipient address
    /// @param amount The transferred amount
    event PublicTransfer(address indexed from, address indexed to, uint256 indexed amount);

    /// @notice Emitted when a private transfer is initiated
    /// @param from The sender address
    /// @param to The recipient address
    /// @param commitment The commitment hash for the private transfer
    event PrivateTransferInitiated(address indexed from, address indexed to, bytes32 commitment);
    
    /**
     * @notice Initialize the dual-mode token with initial supply
     * @dev Mints 1 million tokens to the deployer for testing dual-mode functionality
     */
    constructor() ERC20("Dual Mode Token", "DUAL") Ownable(msg.sender) {
        _mint(msg.sender, 1000000 * 10**decimals());
    }
    
    /**
     * @notice Standard public transfer with event emission
     * @dev Overrides ERC20 transfer to emit custom public transfer event
     * @param to The recipient address
     * @param amount The amount to transfer
     * @return success Whether the transfer succeeded
     */
    function transfer(address to, uint256 amount) public override returns (bool success) {
        bool result = super.transfer(to, amount);
        if (result) {
            emit PublicTransfer(msg.sender, to, amount);
        }
        return result;
    }
    
    /**
     * @notice Initiate a private transfer (conceptual example)
     * @dev This is a placeholder showing how private transfers could be initiated.
     *      In practice, this would interact with a separate PrivateERC20 contract.
     * @param to The recipient address for the private transfer
     * @param amount The amount to transfer privately
     * @param privateTokenContract The private token contract address
     * @return commitment The commitment hash for the private transfer
     */
    function initiatePrivateTransfer(
        address to, 
        uint256 amount,
        address privateTokenContract
    ) public returns (bytes32 commitment) {
        // Transfer to bridge/escrow
        _transfer(msg.sender, privateTokenContract, amount);
        
        // Create commitment hash (simplified)
        commitment = keccak256(
            abi.encodePacked(msg.sender, to, amount, block.timestamp)
        ); // solhint-disable-line not-rely-on-time
        
        emit PrivateTransferInitiated(msg.sender, to, commitment);
        return commitment;
    }
}