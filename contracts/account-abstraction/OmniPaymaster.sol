// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IPaymaster} from "./interfaces/IPaymaster.sol";
import {UserOperation} from "./interfaces/IAccount.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title OmniPaymaster
 * @author OmniCoin Development Team
 * @notice ERC-4337 Paymaster that sponsors gas for OmniCoin users
 * @dev Provides three sponsorship modes:
 *      1. Free gas for new users (first N transactions per account)
 *      2. Gas payment in XOM token (deducted from user's XOM balance)
 *      3. Validator subsidy (funded by staking rewards/ODDAO)
 *
 *      On OmniCoin L1 where gas is effectively free for validators,
 *      this paymaster serves to formally comply with ERC-4337 while
 *      enabling gasless user experience.
 */
contract OmniPaymaster is IPaymaster, Ownable {
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════
    //                     TYPE DECLARATIONS
    // ══════════════════════════════════════════════════════════════

    /// @notice Sponsorship mode
    enum SponsorMode {
        /// @dev Free gas (new user welcome period)
        free,
        /// @dev Pay gas in XOM tokens
        xomPayment,
        /// @dev Validator/ODDAO subsidized
        subsidized
    }

    // ══════════════════════════════════════════════════════════════
    //                        CONSTANTS
    // ══════════════════════════════════════════════════════════════

    /// @notice Default number of free sponsored operations per new account
    uint256 public constant DEFAULT_FREE_OPS = 10;

    /// @notice Maximum allowed free operations per account
    uint256 public constant MAX_FREE_OPS = 100;

    /// @notice Nominal XOM fee per operation (0.001 XOM = 1e15 wei at 18 decimals)
    uint256 public constant XOM_GAS_FEE = 1e15;

    // ══════════════════════════════════════════════════════════════
    //                      STATE VARIABLES
    // ══════════════════════════════════════════════════════════════

    /// @notice The ERC-4337 EntryPoint contract
    address public immutable entryPoint; // solhint-disable-line immutable-vars-naming

    /// @notice XOM token contract for gas payment mode
    IERC20 public immutable xomToken; // solhint-disable-line immutable-vars-naming

    /// @notice Number of free operations per new account
    uint256 public freeOpsLimit;

    /// @notice Count of sponsored operations per account
    mapping(address => uint256) public sponsoredOpsCount;

    /// @notice Whether an account is whitelisted for unlimited sponsorship
    mapping(address => bool) public whitelisted;

    /// @notice Whether global sponsorship is enabled (emergency kill switch)
    bool public sponsorshipEnabled;

    /// @notice Total gas sponsored (for stats)
    uint256 public totalGasSponsored;

    /// @notice Total operations sponsored (for stats)
    uint256 public totalOpsSponsored;

    /// @notice Maximum number of free/subsidized operations allowed per day (0 = unlimited)
    uint256 public dailySponsorshipBudget;

    /// @notice Number of free/subsidized operations consumed in the current day
    uint256 public dailySponsorshipUsed;

    /// @notice Timestamp of last daily budget reset (midnight UTC boundary)
    uint256 public lastBudgetReset;

    // ══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ══════════════════════════════════════════════════════════════

    /// @notice Emitted when gas is sponsored for a user
    /// @param account The account that received sponsorship
    /// @param mode The sponsorship mode used
    /// @param gasCost Gas cost that was sponsored
    event GasSponsored(address indexed account, SponsorMode mode, uint256 gasCost);

    /// @notice Emitted when XOM is collected for gas payment
    /// @param account The account that paid in XOM
    /// @param xomAmount Amount of XOM collected
    event XOMGasPayment(address indexed account, uint256 indexed xomAmount);

    /// @notice Emitted when an account is whitelisted
    /// @param account The whitelisted account
    event AccountWhitelisted(address indexed account);

    /// @notice Emitted when an account is removed from whitelist
    /// @param account The removed account
    event AccountUnwhitelisted(address indexed account);

    /// @notice Emitted when free operations limit is updated
    /// @param newLimit The new limit
    event FreeOpsLimitUpdated(uint256 indexed newLimit);

    /// @notice Emitted when sponsorship is toggled
    /// @param enabled Whether sponsorship is now enabled
    event SponsorshipToggled(bool indexed enabled);

    /// @notice Emitted when the daily sponsorship budget is updated
    /// @param newBudget The new daily budget (0 = unlimited)
    event DailySponsorshipBudgetUpdated(uint256 indexed newBudget);

    // ══════════════════════════════════════════════════════════════
    //                       CUSTOM ERRORS
    // ══════════════════════════════════════════════════════════════

    /// @notice Caller is not the EntryPoint
    error OnlyEntryPoint();

    /// @notice Sponsorship is currently disabled
    error SponsorshipDisabled();

    /// @notice Account has exceeded free operation limit and has no XOM
    error NotSponsored();

    /// @notice Daily sponsorship budget has been exhausted
    error DailyBudgetExhausted();

    /// @notice Invalid address (zero)
    error InvalidAddress();

    /// @notice Limit exceeds maximum
    error ExceedsMaxLimit();

    // ══════════════════════════════════════════════════════════════
    //                        MODIFIERS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Restricts access to the EntryPoint contract only
     */
    modifier onlyEntryPointCaller() {
        if (msg.sender != entryPoint) revert OnlyEntryPoint();
        _;
    }

    // ══════════════════════════════════════════════════════════════
    //                       CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the paymaster
     * @param entryPoint_ The ERC-4337 EntryPoint contract
     * @param xomToken_ The XOM token contract for gas payment
     * @param owner_ The paymaster owner (can manage settings)
     */
    constructor(
        address entryPoint_,
        address xomToken_,
        address owner_
    ) Ownable(owner_) {
        if (entryPoint_ == address(0)) revert InvalidAddress();
        if (xomToken_ == address(0)) revert InvalidAddress();

        entryPoint = entryPoint_;
        xomToken = IERC20(xomToken_);
        freeOpsLimit = DEFAULT_FREE_OPS;
        sponsorshipEnabled = true;
        dailySponsorshipBudget = 1000; // Default: 1000 sponsored ops per day
        // solhint-disable-next-line not-rely-on-time
        lastBudgetReset = block.timestamp;
    }

    // ══════════════════════════════════════════════════════════════
    //                   ERC-4337 PAYMASTER
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Validate whether to sponsor this UserOperation
     * @dev Sponsorship decision logic:
     *      1. If whitelisted → always sponsor (SponsorMode.subsidized)
     *      2. If under free ops limit → sponsor free (SponsorMode.free)
     *      3. If user has XOM balance → accept XOM payment (SponsorMode.xomPayment)
     *      4. Otherwise → reject (revert NotSponsored)
     * @param userOp The UserOperation requesting sponsorship
     * @param userOpHash Hash of the UserOperation (unused, for interface compliance)
     * @param maxCost Maximum cost that could be charged (unused on our L1)
     * @return context Encoded sponsor mode + account for postOp
     * @return validationData Always 0 (valid, no time restriction)
     */
    function validatePaymasterUserOp(
        UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external override onlyEntryPointCaller returns (bytes memory context, uint256 validationData) {
        // Silence unused parameter warnings
        (userOpHash, maxCost);

        if (!sponsorshipEnabled) revert SponsorshipDisabled();

        address account = userOp.sender;
        SponsorMode mode;

        if (whitelisted[account]) {
            mode = SponsorMode.subsidized;
        } else if (sponsoredOpsCount[account] < freeOpsLimit) {
            mode = SponsorMode.free;
        } else if (
            xomToken.balanceOf(account) > XOM_GAS_FEE - 1
            && xomToken.allowance(account, address(this)) > XOM_GAS_FEE - 1
        ) {
            mode = SponsorMode.xomPayment;
        } else {
            revert NotSponsored();
        }

        // Enforce daily sponsorship budget for non-XOM modes (sybil protection)
        if (mode != SponsorMode.xomPayment) {
            _checkDailyBudget();
        }

        context = abi.encode(mode, account);
        return (context, 0);
    }

    /**
     * @notice Post-operation accounting after UserOp execution
     * @dev Updates sponsorship counters and collects XOM payment if applicable.
     * @param mode Whether the operation succeeded or reverted
     * @param context Data from validatePaymasterUserOp (sponsor mode + account)
     * @param actualGasCost Actual gas cost charged
     */
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost
    ) external override onlyEntryPointCaller {
        // Decode context
        (SponsorMode sponsorMode, address account) = abi.decode(context, (SponsorMode, address));

        // Only update counters on successful operations (failed ops should not
        // consume the user's free ops allocation)
        if (mode == PostOpMode.opSucceeded) {
            ++sponsoredOpsCount[account];
            ++totalOpsSponsored;
            totalGasSponsored += actualGasCost;
        }

        // For XOM payment mode, collect a nominal XOM fee only on success
        // On OmniCoin L1, gas is effectively free, so this is a micro-fee
        if (
            sponsorMode == SponsorMode.xomPayment
            && mode == PostOpMode.opSucceeded
        ) {
            // Validated in validatePaymasterUserOp: balance and allowance > XOM_GAS_FEE - 1
            xomToken.safeTransferFrom(account, owner(), XOM_GAS_FEE);
            emit XOMGasPayment(account, XOM_GAS_FEE);
        }

        emit GasSponsored(account, sponsorMode, actualGasCost);
    }

    // ══════════════════════════════════════════════════════════════
    //                    ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Add an account to the sponsorship whitelist
     * @param account Account to whitelist
     */
    function whitelistAccount(address account) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        whitelisted[account] = true;
        emit AccountWhitelisted(account);
    }

    /**
     * @notice Remove an account from the sponsorship whitelist
     * @param account Account to remove
     */
    function unwhitelistAccount(address account) external onlyOwner {
        whitelisted[account] = false;
        emit AccountUnwhitelisted(account);
    }

    /**
     * @notice Update the free operations limit for new accounts
     * @param newLimit New limit (must be <= MAX_FREE_OPS)
     */
    function setFreeOpsLimit(uint256 newLimit) external onlyOwner {
        if (newLimit > MAX_FREE_OPS) revert ExceedsMaxLimit();
        freeOpsLimit = newLimit;
        emit FreeOpsLimitUpdated(newLimit);
    }

    /**
     * @notice Enable or disable sponsorship (emergency kill switch)
     * @param enabled Whether to enable sponsorship
     */
    function setSponsorshipEnabled(bool enabled) external onlyOwner {
        sponsorshipEnabled = enabled;
        emit SponsorshipToggled(enabled);
    }

    /**
     * @notice Deposit native tokens to the EntryPoint for gas
     * @dev Required for the paymaster to function — the EntryPoint deducts
     *      gas costs from this deposit.
     */
    function deposit() external payable onlyOwner {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = entryPoint.call{value: msg.value}(
            abi.encodeWithSignature("depositTo(address)", address(this))
        );
        if (!success) revert InvalidAddress();
    }

    /**
     * @notice Withdraw native tokens from the EntryPoint deposit
     * @param amount Amount to withdraw
     * @param to Recipient address
     */
    function withdrawDeposit(uint256 amount, address payable to) external onlyOwner {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = entryPoint.call(
            abi.encodeWithSignature("withdrawTo(address,uint256)", to, amount)
        );
        if (!success) revert InvalidAddress();
    }

    /**
     * @notice Set the daily sponsorship budget
     * @dev Controls the maximum number of free/subsidized operations per day.
     *      Set to 0 to disable the daily limit (unlimited sponsorship).
     * @param newBudget The new daily budget (operations per day, 0 = unlimited)
     */
    function setDailySponsorshipBudget(uint256 newBudget) external onlyOwner {
        dailySponsorshipBudget = newBudget;
        emit DailySponsorshipBudgetUpdated(newBudget);
    }

    /**
     * @notice Get remaining free operations for an account
     * @param account The account to query
     * @return remaining Number of free operations remaining
     */
    function remainingFreeOps(address account) external view returns (uint256 remaining) {
        uint256 used = sponsoredOpsCount[account];
        if (used > freeOpsLimit - 1) return 0;
        return freeOpsLimit - used;
    }

    // ══════════════════════════════════════════════════════════════
    //                    INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Check and update the daily sponsorship budget
     * @dev Resets the counter when a new day begins (24h period from last reset).
     *      Reverts if the daily budget has been exhausted.
     *      If dailySponsorshipBudget is 0, the budget is unlimited.
     */
    function _checkDailyBudget() internal {
        if (dailySponsorshipBudget == 0) return; // Unlimited

        // Reset counter if 24 hours have passed since last reset
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > lastBudgetReset + 1 days - 1) {
            dailySponsorshipUsed = 0;
            // solhint-disable-next-line not-rely-on-time
            lastBudgetReset = block.timestamp;
        }

        if (dailySponsorshipUsed > dailySponsorshipBudget - 1) {
            revert DailyBudgetExhausted();
        }

        ++dailySponsorshipUsed;
    }
}
