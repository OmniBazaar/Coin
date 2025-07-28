// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title TestTarget
 * @dev Simple test contract for governance proposal execution testing
 */
contract TestTarget {
    uint256 public value;
    
    event ValueSet(uint256 newValue);
    event EtherReceived(address sender, uint256 amount);
    
    /**
     * @dev Sets a new value
     * @param _value The new value to set
     */
    function setValue(uint256 _value) external {
        value = _value;
        emit ValueSet(_value);
    }
    
    /**
     * @dev Receives ether
     */
    function receiveEther() external payable {
        require(msg.value > 0, "Must send ether");
        emit EtherReceived(msg.sender, msg.value);
    }
    
    /**
     * @dev Fallback function to receive ether
     */
    receive() external payable {
        emit EtherReceived(msg.sender, msg.value);
    }
}