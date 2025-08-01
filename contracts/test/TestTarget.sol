// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title TestTarget
 * @author OmniCoin Development Team
 * @notice Simple test contract for governance proposal execution testing
 * @dev Used for testing governance proposal execution
 */
contract TestTarget {
    /// @notice Current stored value
    uint256 public value;
    
    /// @notice Emitted when value is updated
    /// @param newValue The new value that was set
    event ValueSet(uint256 indexed newValue);
    
    /// @notice Emitted when ether is received
    /// @param sender Address that sent the ether
    /// @param amount Amount of ether received
    event EtherReceived(address indexed sender, uint256 indexed amount);
    
    /**
     * @notice Sets a new value
     * @param _value The new value to set
     */
    function setValue(uint256 _value) external {
        value = _value;
        emit ValueSet(_value);
    }
    
    /**
     * @notice Receives ether with validation
     */
    function receiveEther() external payable {
        if (msg.value == 0) revert("Must send ether");
        emit EtherReceived(msg.sender, msg.value);
    }
    
    /**
     * @notice Fallback function to receive ether
     */
    receive() external payable {
        emit EtherReceived(msg.sender, msg.value);
    }
}