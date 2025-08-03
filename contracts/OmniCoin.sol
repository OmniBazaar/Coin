// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title OmniCoin
 * @author OmniCoin Development Team
 * @notice Simplified ERC20 token for OmniBazaar ecosystem
 * @dev Public token with role-based minting and burning
 * 
 * Key features:
 * - 18 decimal places for full Ethereum compatibility
 * - Role-based access control for minting/burning
 * - Pausable for emergency stops
 * - ERC20Permit for gasless approvals
 * - Initial supply of 1 billion tokens
 */
contract OmniCoin is ERC20, ERC20Burnable, ERC20Pausable, ERC20Permit, AccessControl {
    // Roles
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    
    // Constants
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10**18; // 1 billion tokens
    
    /**
     * @notice Initialize OmniCoin token
     * @dev Mints initial supply to deployer
     */
    function initialize() external {
        require(totalSupply() == 0, "Already initialized");
        
        // Grant roles to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
        
        // Mint initial supply
        _mint(msg.sender, INITIAL_SUPPLY);
    }
    
    /**
     * @notice Constructor for OmniCoin
     * @dev Sets up ERC20 with name, symbol, and ERC20Permit
     */
    constructor() ERC20("OmniCoin", "XOM") ERC20Permit("OmniCoin") {
        // Empty constructor - initialization done in initialize()
    }
    
    /**
     * @notice Mint new tokens
     * @dev Only MINTER_ROLE can mint
     * @param to Address to mint tokens to
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }
    
    /**
     * @notice Burn tokens from an address
     * @dev Only BURNER_ROLE can burn from others
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address from, uint256 amount) public override onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }
    
    /**
     * @notice Pause all token transfers
     * @dev Only admin can pause
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause token transfers
     * @dev Only admin can unpause
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Override required for multiple inheritance
     * @dev Applies pausable check before transfers
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Pausable) {
        super._update(from, to, amount);
    }
}