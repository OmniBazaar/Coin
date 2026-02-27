// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IPaymaster} from "./interfaces/IPaymaster.sol";
import {IEntryPoint} from "./interfaces/IEntryPoint.sol";
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

    /// @notice Default XOM fee per operation (0.001 XOM = 1e15 wei at 18 decimals)
    uint256 public constant DEFAULT_XOM_GAS_FEE = 1e15;

    // ══════════════════════════════════════════════════════════════
    //                      STATE VARIABLES
    // ══════════════════════════════════════════════════════════════

    /// @notice The ERC-4337 EntryPoint contract
    IEntryPoint public immutable entryPoint; // solhint-disable-line immutable-vars-naming

    /// @notice XOM token contract for gas payment mode
    IERC20 public immutable xomToken; // solhint-disable-line immutable-vars-naming

    /// @notice OmniRegistration contract for sybil-resistant user checks
    /// @dev Set to address(0) to disable registration checks.
    ///      When set, only registered users receive free gas (M-01).
    address public registration;

    /// @notice Configurable XOM fee per operation (L-02)
    /// @dev Allows adjusting the fee as XOM price changes
    uint256 public xomGasFee;

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

    /// @notice Emitted when the XOM gas fee is updated
    /// @param newFee The new fee amount
    event XomGasFeeUpdated(uint256 indexed newFee);

    /// @notice Emitted when the registration contract is updated
    /// @param newRegistration The new registration contract address
    event RegistrationUpdated(address indexed newRegistration);

    /// @notice Emitted when tokens are rescued from the contract
    /// @param token The token rescued
    /// @param to Recipient address
    /// @param amount Amount rescued
    event TokensRescued(
        address indexed token,
        address indexed to,
        uint256 indexed amount
    );

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

    /// @notice EntryPoint call failed
    error EntryPointCallFailed();

    // ══════════════════════════════════════════════════════════════
    //                        MODIFIERS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Restricts access to the EntryPoint contract only
     */
    modifier onlyEntryPointCaller() {
        if (msg.sender != address(entryPoint)) revert OnlyEntryPoint();
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

        entryPoint = IEntryPoint(entryPoint_);
        xomToken = IERC20(xomToken_);
        xomGasFee = DEFAULT_XOM_GAS_FEE;
        freeOpsLimit = DEFAULT_FREE_OPS;
        sponsorshipEnabled = true;
        dailySponsorshipBudget = 1000;
        // solhint-disable-next-line not-rely-on-time
        lastBudgetReset = block.timestamp;
    }

    // ══════════════════════════════════════════════════════════════
    //                   ERC-4337 PAYMASTER
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Validate whether to sponsor this UserOperation
     * @dev Sponsorship decision logic:
     *      1. If whitelisted -> always sponsor (SponsorMode.subsidized)
     *      2. If registered and under free ops limit -> sponsor free
     *      3. If user has XOM balance -> accept XOM payment
     *      4. Otherwise -> reject (revert NotSponsored)
     *
     *      H-01: XOM fee is collected DURING validation (not postOp)
     *      to prevent free-riding via allowance revocation.
     *      M-01: Registration check for sybil resistance.
     * @param userOp The UserOperation requesting sponsorship
     * @param userOpHash Hash of the UserOperation (unused)
     * @param maxCost Maximum cost that could be charged (unused on L1)
     * @return context Encoded sponsor mode + account for postOp
     * @return validationData Always 0 (valid, no time restriction)
     */
    function validatePaymasterUserOp(
        UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external override onlyEntryPointCaller returns (
        bytes memory context,
        uint256 validationData
    ) {
        // Silence unused parameter warnings
        (userOpHash, maxCost);

        if (!sponsorshipEnabled) revert SponsorshipDisabled();

        address account = userOp.sender;
        SponsorMode mode = _determineSponsorMode(account);

        // Enforce daily budget for non-XOM modes (sybil protection)
        if (mode != SponsorMode.xomPayment) {
            _checkDailyBudget();
        }

        // H-01: Collect XOM fee during validation to prevent
        // free-riding via allowance revocation during execution.
        // If the transfer fails here, the entire validation reverts,
        // and the UserOp is rejected.
        if (mode == SponsorMode.xomPayment) {
            uint256 fee = xomGasFee;
            xomToken.safeTransferFrom(account, owner(), fee);
            emit XOMGasPayment(account, fee);
        }

        context = abi.encode(mode, account);
        return (context, 0);
    }

    /**
     * @notice Post-operation accounting after UserOp execution
     * @dev M-02: GasSponsored event only emitted on opSucceeded.
     *      XOM fee collection moved to validatePaymasterUserOp (H-01).
     * @param mode Whether the operation succeeded or reverted
     * @param context Data from validatePaymasterUserOp
     * @param actualGasCost Actual gas cost charged
     */
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost
    ) external override onlyEntryPointCaller {
        (SponsorMode sponsorMode, address account) = abi.decode(
            context, (SponsorMode, address)
        );

        // M-02: Only update counters and emit event on success
        if (mode == PostOpMode.opSucceeded) {
            ++sponsoredOpsCount[account];
            ++totalOpsSponsored;
            totalGasSponsored += actualGasCost;
            emit GasSponsored(account, sponsorMode, actualGasCost);
        }
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
     * @dev H-02: Uses typed IEntryPoint interface for compile-time safety.
     *      Required for the paymaster to function -- the EntryPoint deducts
     *      gas costs from this deposit.
     */
    function deposit() external payable onlyOwner {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    /**
     * @notice Withdraw native tokens from the EntryPoint deposit
     * @dev H-02: Uses low-level call with proper error type.
     *      Validates recipient is not zero address.
     * @param amount Amount to withdraw
     * @param to Recipient address
     */
    function withdrawDeposit(
        uint256 amount,
        address payable to
    ) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = address(entryPoint).call(
            abi.encodeWithSignature(
                "withdrawTo(address,uint256)", to, amount
            )
        );
        if (!success) revert EntryPointCallFailed();
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
     * @notice Update the XOM gas fee (L-02)
     * @dev Allows adjusting the per-operation XOM fee as market conditions change
     * @param newFee The new XOM fee per operation (in wei)
     */
    function setXomGasFee(uint256 newFee) external onlyOwner {
        xomGasFee = newFee;
        emit XomGasFeeUpdated(newFee);
    }

    /**
     * @notice Set the OmniRegistration contract for sybil resistance (M-01)
     * @dev Set to address(0) to disable registration checks
     * @param registration_ The OmniRegistration contract address
     */
    function setRegistration(address registration_) external onlyOwner {
        registration = registration_;
        emit RegistrationUpdated(registration_);
    }

    /**
     * @notice Add multiple accounts to the whitelist in one transaction (L-03)
     * @param accounts Array of accounts to whitelist
     */
    function whitelistAccountBatch(
        address[] calldata accounts
    ) external onlyOwner {
        uint256 len = accounts.length;
        for (uint256 i; i < len; ++i) {
            if (accounts[i] == address(0)) revert InvalidAddress();
            whitelisted[accounts[i]] = true;
            emit AccountWhitelisted(accounts[i]);
        }
    }

    /**
     * @notice Rescue ERC-20 tokens accidentally sent to this contract (M-04)
     * @dev Only callable by the owner. Useful for recovering tokens sent
     *      directly to the paymaster address by mistake.
     * @param token The ERC-20 token to rescue
     * @param to Recipient of the rescued tokens
     * @param amount Amount to rescue
     */
    function rescueTokens(
        IERC20 token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        token.safeTransfer(to, amount);
        emit TokensRescued(address(token), to, amount);
    }

    /**
     * @notice Get remaining free operations for an account
     * @dev L-01: Handles freeOpsLimit==0 without underflow
     * @param account The account to query
     * @return remaining Number of free operations remaining
     */
    function remainingFreeOps(
        address account
    ) external view returns (uint256 remaining) {
        uint256 used = sponsoredOpsCount[account];
        if (freeOpsLimit == 0 || used > freeOpsLimit - 1) return 0;
        return freeOpsLimit - used;
    }

    // ══════════════════════════════════════════════════════════════
    //                    INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Check and update the daily sponsorship budget
     * @dev M-03: Uses calendar-day boundaries (midnight UTC) instead of
     *      rolling 24h windows. This prevents drift and provides
     *      consistent, predictable budget windows.
     *      If dailySponsorshipBudget is 0, the budget is unlimited.
     */
    function _checkDailyBudget() internal {
        if (dailySponsorshipBudget == 0) return; // Unlimited

        // M-03: Use calendar-day boundaries for consistent budget windows
        // solhint-disable-next-line not-rely-on-time
        uint256 currentDay = block.timestamp / 1 days;
        uint256 lastResetDay = lastBudgetReset / 1 days;

        if (currentDay > lastResetDay) {
            dailySponsorshipUsed = 0;
            // solhint-disable-next-line not-rely-on-time
            lastBudgetReset = block.timestamp;
        }

        if (dailySponsorshipUsed > dailySponsorshipBudget - 1) {
            revert DailyBudgetExhausted();
        }

        ++dailySponsorshipUsed;
    }

    /**
     * @notice Determine sponsorship mode for an account
     * @dev M-01: When registration is set, free ops require registration.
     * @param account The account requesting sponsorship
     * @return mode The determined sponsorship mode
     */
    function _determineSponsorMode(
        address account
    ) internal view returns (SponsorMode mode) {
        if (whitelisted[account]) {
            return SponsorMode.subsidized;
        }

        // M-01: Check registration for free ops (sybil resistance)
        bool isRegistered = true;
        if (registration != address(0)) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, bytes memory result) = registration.staticcall(
                abi.encodeWithSignature(
                    "isRegistered(address)", account
                )
            );
            if (ok && result.length > 31) {
                isRegistered = abi.decode(result, (bool));
            }
        }

        if (isRegistered && sponsoredOpsCount[account] < freeOpsLimit) {
            return SponsorMode.free;
        }

        uint256 fee = xomGasFee;
        if (
            fee > 0
            && xomToken.balanceOf(account) > fee - 1
            && xomToken.allowance(account, address(this)) > fee - 1
        ) {
            return SponsorMode.xomPayment;
        }

        revert NotSponsored();
    }
}
