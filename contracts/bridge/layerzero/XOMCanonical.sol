// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title XOMCanonical
 * @author OmniCoin Development Team
 * @notice Canonical XOM ERC-20 on Avalanche C-Chain for the LayerZero OFT bridge mesh
 * @dev This is a minimal ERC-20 representing XOM on Avalanche C-Chain (43114).
 *      It serves as the escrow supply for the XOMOftAdapter, which locks these
 *      tokens and mints corresponding XOMOft tokens on remote chains (Ethereum,
 *      Arbitrum, Base, Polygon).
 *
 *      The native XOM (on OmniBazaar L1, chain 88008) is bridged to C-Chain via
 *      ICTT; this canonical ERC-20 is what the OFTAdapter wraps for LayerZero
 *      cross-chain transport. Its total supply equals the sum of all XOMOft
 *      totalSupply() on remote chains plus any unlocked balance held by the
 *      OFTAdapter.
 *
 *      Supply invariant:
 *        XOMCanonical.totalSupply() ==
 *          XOMOftAdapter.balance(XOMCanonical) + sum(XOMOft.totalSupply() on remotes)
 *
 *      Security:
 *        - ownerMint() is restricted to the contract owner (deployer initially)
 *        - MAX_SUPPLY hard cap of 16.6 billion XOM enforced at the contract level
 *        - Ownership uses 2-step transfer (Ownable2Step) to prevent accidental loss
 *        - Owner should be transferred to a timelocked multisig post-launch
 *        - Minting is only used to seed the OFTAdapter with enough supply for
 *          the cross-chain mesh; it is NOT open-ended inflation
 *
 *      This contract does NOT implement burning. The OFTAdapter handles
 *      lock/unlock mechanics; XOMCanonical tokens are never destroyed, only
 *      transferred between the adapter and users on C-Chain.
 */
contract XOMCanonical is ERC20, Ownable2Step {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Hard cap on total XOM supply — matches the native XOM cap on L1 (chain 88008)
    /// @dev 16.6 billion tokens with 18 decimals. This cap is immutable and enforced in
    ///      both the constructor and ownerMint(). Even a compromised owner key cannot
    ///      mint beyond this limit.
    uint256 public constant MAX_SUPPLY = 16_600_000_000e18;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when the owner mints new tokens
    /// @param to Recipient of the minted tokens
    /// @param amount Number of tokens minted (18 decimals)
    event OwnerMint(address indexed to, uint256 indexed amount);

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Thrown when attempting to mint to the zero address
    error MintToZeroAddress();

    /// @notice Thrown when attempting to mint zero tokens
    error MintZeroAmount();

    /// @notice Thrown when a mint would exceed the MAX_SUPPLY hard cap
    /// @param requested The amount of tokens requested to mint
    /// @param available The remaining mintable supply (MAX_SUPPLY - totalSupply)
    error ExceedsMaxSupply(uint256 requested, uint256 available);

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /**
     * @notice Deploys XOMCanonical with an initial mint to the deployer
     * @param _initialMint Amount of XOM to mint to the deployer at construction
     *        (in whole tokens — will be scaled to 18 decimals internally)
     * @dev The initial mint provides enough supply to seed remote-chain pools
     *      via the OFTAdapter. For 4 remote chains at 2,500 XOM each, plus
     *      reserve for future chains, 1,000,000 XOM is the recommended initial
     *      mint. Name and symbol match the native XOM token for user clarity.
     */
    constructor(
        uint256 _initialMint
    ) ERC20("OmniCoin", "XOM") Ownable(msg.sender) {
        if (_initialMint > 0) {
            uint256 scaled = _initialMint * 10 ** decimals();
            if (scaled > MAX_SUPPLY) revert ExceedsMaxSupply(scaled, MAX_SUPPLY);
            _mint(msg.sender, scaled);
            emit OwnerMint(msg.sender, scaled);
        }
    }

    // ========================================================================
    // EXTERNAL FUNCTIONS
    // ========================================================================

    /**
     * @notice Mint XOM tokens to a specified address, subject to MAX_SUPPLY cap
     * @param _to Recipient of the minted tokens
     * @param _amount Amount of tokens to mint (in wei, 18 decimals)
     * @dev Only callable by the contract owner. Used to top up the OFTAdapter
     *      escrow when expanding to new remote chains or replenishing bridge
     *      liquidity. Reverts with ExceedsMaxSupply if the mint would push
     *      totalSupply() above MAX_SUPPLY (16.6B XOM). The owner must be a
     *      timelocked multisig in production.
     */
    function ownerMint(address _to, uint256 _amount) external onlyOwner {
        if (_to == address(0)) revert MintToZeroAddress();
        if (_amount == 0) revert MintZeroAmount();
        uint256 available = MAX_SUPPLY - totalSupply();
        if (_amount > available) revert ExceedsMaxSupply(_amount, available);
        _mint(_to, _amount);
        emit OwnerMint(_to, _amount);
    }

}
