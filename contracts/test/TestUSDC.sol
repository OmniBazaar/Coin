// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TestUSDC
 * @author OmniCoin Development Team
 * @notice Mintable test stablecoin for DEX liquidity testing on Fuji testnet
 * @dev This is a test token that mimics USDC with 6 decimals.
 *      Anyone can mint tokens for testing purposes.
 *      DO NOT USE IN PRODUCTION - this is for testnet only.
 */
contract TestUSDC is ERC20, Ownable {
    /// @notice Token decimals (matches real USDC)
    uint8 private constant DECIMALS = 6;

    /// @notice Maximum mint amount per call (1 million USDC)
    uint256 public constant MAX_MINT_AMOUNT = 1_000_000 * 10 ** DECIMALS;

    /// @notice Cooldown period between mints for same address (1 hour)
    uint256 public constant MINT_COOLDOWN = 1 hours;

    /// @notice Tracks last mint timestamp per address
    mapping(address => uint256) public lastMintTime;

    /// @notice Emitted when tokens are minted
    /// @param to Recipient address
    /// @param amount Amount minted
    event TokensMinted(address indexed to, uint256 amount);

    /// @notice Emitted when faucet drip is triggered
    /// @param recipient Recipient of faucet drip
    /// @param amount Amount dripped
    event FaucetDrip(address indexed recipient, uint256 amount);

    /// @dev Error thrown when mint amount exceeds maximum
    error MintAmountExceedsMax(uint256 requested, uint256 maximum);

    /// @dev Error thrown when mint cooldown has not elapsed
    error MintCooldownActive(uint256 remainingTime);

    /**
     * @notice Initialize TestUSDC with initial supply to deployer
     * @dev Mints 100 million tokens to deployer for initial liquidity seeding
     */
    constructor() ERC20("Test USD Coin", "TestUSDC") Ownable(msg.sender) {
        // Mint 100 million to deployer for initial liquidity
        _mint(msg.sender, 100_000_000 * 10 ** DECIMALS);
    }

    /**
     * @notice Returns the number of decimals (6, like real USDC)
     * @return decimalsValue The number of decimals
     */
    function decimals() public pure override returns (uint8 decimalsValue) {
        return DECIMALS;
    }

    /**
     * @notice Mint tokens to any address (rate-limited)
     * @dev Anyone can call this for testing. Has cooldown to prevent spam.
     * @param to Recipient address
     * @param amount Amount to mint (max 1 million per call)
     */
    function mint(address to, uint256 amount) external {
        if (amount > MAX_MINT_AMOUNT) {
            revert MintAmountExceedsMax(amount, MAX_MINT_AMOUNT);
        }

        uint256 timeSinceLastMint = block.timestamp - lastMintTime[msg.sender]; // solhint-disable-line not-rely-on-time
        if (timeSinceLastMint < MINT_COOLDOWN) {
            revert MintCooldownActive(MINT_COOLDOWN - timeSinceLastMint);
        }

        lastMintTime[msg.sender] = block.timestamp; // solhint-disable-line not-rely-on-time
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    /**
     * @notice Owner-only mint without restrictions (for initial setup)
     * @dev Used for seeding liquidity pools and initial distribution
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function ownerMint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    /**
     * @notice Faucet function - get 10,000 TestUSDC for testing
     * @dev Simple faucet for users to get test tokens
     */
    function faucet() external {
        uint256 dripAmount = 10_000 * 10 ** DECIMALS;

        uint256 timeSinceLastMint = block.timestamp - lastMintTime[msg.sender]; // solhint-disable-line not-rely-on-time
        if (timeSinceLastMint < MINT_COOLDOWN) {
            revert MintCooldownActive(MINT_COOLDOWN - timeSinceLastMint);
        }

        lastMintTime[msg.sender] = block.timestamp; // solhint-disable-line not-rely-on-time
        _mint(msg.sender, dripAmount);
        emit FaucetDrip(msg.sender, dripAmount);
    }

    /**
     * @notice Check remaining cooldown time for an address
     * @param account Address to check
     * @return remainingTime Seconds until next mint allowed (0 if ready)
     */
    function getRemainingCooldown(address account) external view returns (uint256 remainingTime) {
        uint256 timeSinceLastMint = block.timestamp - lastMintTime[account]; // solhint-disable-line not-rely-on-time
        if (timeSinceLastMint >= MINT_COOLDOWN) {
            return 0;
        }
        return MINT_COOLDOWN - timeSinceLastMint;
    }
}
