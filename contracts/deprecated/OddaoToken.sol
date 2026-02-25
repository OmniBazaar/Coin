// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title OddaoToken
 * @author OmniCoin Development Team
 * @notice ERC-20 governance token for the OmniDevelopment DAO (ODDAO)
 * @custom:deprecated ODDAO token distribution handled off-chain pre-mainnet
 * @dev Fixed-supply ERC20 with ERC20Votes (delegation) and ERC20Permit
 *      (gasless approvals). All tokens are minted at deployment to the
 *      specified holders — no further minting is possible. This contract
 *      is designed for migration from Optimism to OmniCoin chain 131313.
 *
 * Features:
 * - ERC20Votes: vote delegation and checkpoint-based voting power snapshots
 * - ERC20Permit: EIP-2612 gasless approvals
 * - Immutable supply: constructor mints all tokens, no mint function exists
 * - Freeze/clawback: governance-controlled emergency powers via timelock
 * - Compatible with OmniGovernance and OpenZeppelin Governor
 *
 * Token holders are LLC members of the RMI-registered ODDAO entity.
 * Distributions from DividendDistributor are dividends on membership interest.
 */
contract OddaoToken is ERC20, ERC20Permit, ERC20Votes {
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Maximum number of holders in the constructor batch mint
    uint256 public constant MAX_INITIAL_HOLDERS = 500;

    // =========================================================================
    // Immutable Variables
    // =========================================================================

    /// @notice Address of the governance timelock controller
    address public immutable GOVERNANCE;

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Whether an account's tokens are frozen (cannot transfer)
    mapping(address => bool) public frozen;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when an account is frozen or unfrozen
    /// @param account The affected account
    /// @param isFrozen Whether the account is now frozen
    event AccountFrozen(address indexed account, bool indexed isFrozen);

    /// @notice Emitted when tokens are clawed back from a frozen account
    /// @param from The account tokens were taken from
    /// @param to The account tokens were sent to (governance treasury)
    /// @param amount Number of tokens clawed back
    event TokensClawedBack(
        address indexed from,
        address indexed to,
        uint256 amount
    );

    // =========================================================================
    // Custom Errors
    // =========================================================================

    /// @notice Thrown when holders and amounts arrays have mismatched lengths
    error ArrayLengthMismatch();

    /// @notice Thrown when constructor receives empty holder arrays
    error EmptyHolderArray();

    /// @notice Thrown when constructor exceeds MAX_INITIAL_HOLDERS
    error TooManyHolders();

    /// @notice Thrown when a holder address is the zero address
    error ZeroAddressHolder();

    /// @notice Thrown when a holder amount is zero
    error ZeroAmount();

    /// @notice Thrown when caller is not the governance timelock
    error OnlyGovernance();

    /// @notice Thrown when transferring from or to a frozen account
    error AccountIsFrozen(address account);

    /// @notice Thrown when governance address is zero
    error InvalidGovernance();

    /// @notice Thrown when clawback target is not frozen
    error AccountNotFrozen(address account);

    /// @notice Thrown when clawback destination is the zero address
    error InvalidClawbackDestination();

    // =========================================================================
    // Modifiers
    // =========================================================================

    /**
     * @notice Restricts function to governance timelock only
     */
    modifier onlyGovernance() {
        if (msg.sender != GOVERNANCE) revert OnlyGovernance();
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @notice Deploy the ODDAO token with initial distribution
     * @dev Mints tokens to all holders in a single transaction. No further
     *      minting is possible after deployment. The governance address
     *      should be the OmniTimelockController for freeze/clawback powers.
     * @param holders Array of initial token holder addresses
     * @param amounts Array of token amounts (18 decimals) per holder
     * @param governance Address of the governance timelock controller
     */
    constructor(
        address[] memory holders,
        uint256[] memory amounts,
        address governance
    )
        ERC20("OmniDevelopment DAO", "ODDAO")
        ERC20Permit("OmniDevelopment DAO")
    {
        if (governance == address(0)) revert InvalidGovernance();
        if (holders.length == 0) revert EmptyHolderArray();
        if (holders.length != amounts.length) revert ArrayLengthMismatch();
        if (holders.length > MAX_INITIAL_HOLDERS) revert TooManyHolders();

        GOVERNANCE = governance;

        for (uint256 i = 0; i < holders.length; ++i) {
            if (holders[i] == address(0)) revert ZeroAddressHolder();
            if (amounts[i] == 0) revert ZeroAmount();
            _mint(holders[i], amounts[i]);
        }
    }

    // =========================================================================
    // External Functions — Governance Emergency Powers
    // =========================================================================

    /**
     * @notice Freeze or unfreeze an account (governance only)
     * @dev Frozen accounts cannot send or receive tokens. This is an
     *      emergency power that requires a governance vote + timelock delay.
     *      Freezing does NOT affect voting power — use delegate() to remove
     *      a frozen account's voting influence.
     * @param account Address to freeze or unfreeze
     * @param freeze True to freeze, false to unfreeze
     */
    function setFrozen(
        address account,
        bool freeze
    ) external onlyGovernance {
        if (account == address(0)) revert ZeroAddressHolder();
        frozen[account] = freeze;
        emit AccountFrozen(account, freeze);
    }

    /**
     * @notice Claw back tokens from a frozen account (governance only)
     * @dev Transfers all tokens from a frozen account to a destination
     *      (typically the governance treasury). Account must be frozen first.
     *      This is a last-resort emergency power for violations.
     * @param from Frozen account to claw back from
     * @param to Destination for clawed-back tokens (treasury)
     */
    function clawback(
        address from,
        address to
    ) external onlyGovernance {
        if (!frozen[from]) revert AccountNotFrozen(from);
        if (to == address(0)) revert InvalidClawbackDestination();

        uint256 balance = balanceOf(from);
        if (balance == 0) revert ZeroAmount();

        // Temporarily unfreeze to allow the transfer, then refreeze
        frozen[from] = false;
        _transfer(from, to, balance);
        frozen[from] = true;

        emit TokensClawedBack(from, to, balance);
    }

    // =========================================================================
    // Public View Functions
    // =========================================================================

    /**
     * @notice Get the current clock value (block number for snapshots)
     * @dev Required by ERC20Votes. Uses block.number as the clock.
     * @return Current block number as uint48
     */
    function clock() public view override returns (uint48) {
        return uint48(block.number);
    }

    /**
     * @notice Get the clock mode description
     * @dev Required by ERC20Votes. Indicates block-number-based checkpoints.
     * @return Clock mode string
     */
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    // =========================================================================
    // Internal Functions — Required Overrides
    // =========================================================================

    /**
     * @notice Hook called on every token transfer (mint, burn, transfer)
     * @dev Enforces freeze check and updates ERC20Votes checkpoints.
     *      Frozen accounts cannot send or receive tokens.
     * @param from Source address (address(0) for mints)
     * @param to Destination address (address(0) for burns)
     * @param value Token amount
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Votes) {
        // Freeze check (skip for mints from constructor)
        if (from != address(0) && frozen[from]) {
            revert AccountIsFrozen(from);
        }
        if (to != address(0) && frozen[to]) {
            revert AccountIsFrozen(to);
        }

        super._update(from, to, value);
    }

    /**
     * @notice Resolve nonce conflict between ERC20Permit and Nonces
     * @param owner Address to query nonce for
     * @return Current nonce
     */
    function nonces(
        address owner
    ) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
