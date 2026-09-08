// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title MockPrivateMintBurn
 * @notice Minimal mock matching the void-return surface of `PrivateERC20`'s
 *         `mint`/`burn`/`transferFrom` so OmniPrivacyBridge_COTI tests can run
 *         without dragging in the full COTI MPC base.
 * @dev `transferFrom` matches the upstream `PrivateERC20` behavior: returns
 *      nothing (audit C-02). Function reverts on insufficient balance/allowance.
 */
contract MockPrivateMintBurn {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    bool public mintShouldRevert;
    bool public burnShouldRevert;
    bool public transferFromShouldRevert;

    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);

    function setMintShouldRevert(bool v) external { mintShouldRevert = v; }
    function setBurnShouldRevert(bool v) external { burnShouldRevert = v; }
    function setTransferFromShouldRevert(bool v) external { transferFromShouldRevert = v; }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        require(!mintShouldRevert, "mock: mint reverted");
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Minted(to, amount);
    }

    function burn(uint256 amount) external {
        require(!burnShouldRevert, "mock: burn reverted");
        require(balanceOf[msg.sender] >= amount, "mock: balance");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Burned(msg.sender, amount);
    }

    /// @dev VOID return — matches PrivateERC20 (audit C-02).
    function transferFrom(address from, address to, uint256 amount) external {
        require(!transferFromShouldRevert, "mock: transferFrom reverted");
        require(balanceOf[from] >= amount, "mock: balance");
        require(allowance[from][msg.sender] >= amount, "mock: allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
    }
}
