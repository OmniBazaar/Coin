// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./PrivateERC20/PrivateERC20.sol";
import "../utils/mpc/MpcCore.sol";

contract PERCI is PrivateERC20 {
    address public owner;
    uint64 private _totalSupply;


    // Address to receive the initial pre-minted tokens
    address private constant _PRE_MINT_RECEIVER = 0xfAF7e0962B79675cd046C4c0bF41beEb27FCc5C8;
    // Amount of tokens to pre-mint (100,000 tokens with 6 decimals, matching PrivateERC20.decimals())
    uint256 private constant _PRE_MINT_AMOUNT = 100_000 * (10**6);

    // Maximum total supply for the token (10,000,000 tokens with 18 decimals)
    uint256 public constant MAX_SUPPLY = 10_000_000 * (10**18);

    constructor() PrivateERC20("PERCI Token", "PERCI") {
        owner = msg.sender; // Set the deployer as the owner
        // Convert the _PRE_MINT_AMOUNT to gtUint64 for the _mint function
        uint64 preMintAmount64 = uint64(_PRE_MINT_AMOUNT); // Safe because _PRE_MINT_AMOUNT is now 100_000 * 10^6
        gtUint64 fhePreMintAmount = MpcCore.setPublic64(preMintAmount64);
        _mint(_PRE_MINT_RECEIVER, fhePreMintAmount);
        _totalSupply = uint64(_PRE_MINT_AMOUNT);
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function mint(address account, uint64 amount) external {
        gtBool success = _mint(account, MpcCore.setPublic64(amount));

        if (MpcCore.decrypt(success)) {
            _totalSupply += amount;
        }
    }


    function publicTransfer(address to, uint64 value) public returns (gtBool) {
        // require(msg.sender == owner, "PERCI: Caller is not the owner"); // Or other auth
        gtUint64 fheValue = MpcCore.setPublic64(value);
        return _transfer(msg.sender, to, fheValue); // _transfer is internal in PrivateERC20
    }

}