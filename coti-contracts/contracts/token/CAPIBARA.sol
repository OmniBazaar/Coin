// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./PrivateERC20/PrivateERC20.sol";
import "../utils/mpc/MpcCore.sol";

contract CAPIBARA is PrivateERC20 {
    address public owner;
    uint64 private _capibaraTotalSupply; // Using a distinct name for clarity

    // Address to receive the initial pre-minted tokens
    address private constant _PRE_MINT_RECEIVER = 0xfAF7e0962B79675cd046C4c0bF41beEb27FCc5C8;
    // Amount of tokens to pre-mint (100,000 tokens with 6 decimals, matching PrivateERC20.decimals())
    // 100_000 * 10^6 = 100,000,000,000
    uint64 private constant _PRE_MINT_AMOUNT = 100_000 * (10**6); 

    modifier onlyOwner() {
        require(msg.sender == owner, "CAPIBARA: Caller is not the owner");
        _;
    }

    constructor() PrivateERC20("CAPIBARA Token", "CAPI") {
        owner = msg.sender; // Set the deployer as the owner

        // Pre-mint tokens
        // _mint is an internal function from PrivateERC20
        // It handles the FHE logic for creating tokens.
        gtUint64 fhePreMintAmount = MpcCore.setPublic64(_PRE_MINT_AMOUNT);
        _mint(_PRE_MINT_RECEIVER, fhePreMintAmount); // _mint already checks for address(0) receiver
        
        // Initialize the public total supply
        _capibaraTotalSupply = _PRE_MINT_AMOUNT;
    }

    /**
     * @dev Returns the total quantity of tokens in existence.
     * This overrides the function in PrivateERC20 which returns 0.
     */
    function totalSupply() public view override returns (uint256) {
        return _capibaraTotalSupply;
    }

    /**
     * @dev Creates `amount` new tokens for `account`.
     * Can only be called by the owner.
     * Relies on the internal `_mint` function from PrivateERC20.
     * The public total supply is updated based on the success of the FHE operation.
     */
    function mint(address account, uint64 amount) external onlyOwner {
        // _mint will revert if account is address(0)
        gtBool success = _mint(account, MpcCore.setPublic64(amount));

        // Assuming MpcCore.decrypt can be called on-chain to confirm FHE operation success
        // This pattern is borrowed from PERCI.sol
        if (MpcCore.decrypt(success)) {
            _capibaraTotalSupply += amount;
            // Consider adding a MAX_SUPPLY check here if CAPIBARA token should have one
            // require(_capibaraTotalSupply <= MAX_TOTAL_CAPIBARA_SUPPLY, "CAPIBARA: Max supply exceeded");
        } else {
            // If the FHE operation was not successful (e.g., rejected by MPC network, or an FHE constraint violated)
            // it's important to not update the public total supply.
            revert("CAPIBARA: FHE minting operation reported as unsuccessful");
        }
    }

    /**
     * @dev Moves `value` amount of tokens from the caller's account to `to`.
     * This is a wrapper around the internal `_transfer` function of PrivateERC20,
     * allowing transfers with a public `uint64` value.
     * Returns an FHE boolean indicating the success of the FHE transfer operation.
     */
    function publicTransfer(address to, uint64 value) public returns (gtBool) {
        // _transfer is internal in PrivateERC20 and handles FHE logic,
        // including checking sender's balance and that 'to' is not address(0).
        gtUint64 fheValue = MpcCore.setPublic64(value);
        return _transfer(msg.sender, to, fheValue);
    }
}
