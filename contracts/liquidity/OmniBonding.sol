// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title OmniBonding
 * @author OmniCoin Development Team
 * @notice Protocol Owned Liquidity via discounted XOM bond offerings
 * @dev Allows users to exchange assets (USDC, ETH, LP tokens) for
 *      discounted XOM with linear vesting. Protocol permanently owns
 *      the bonded assets. Tracks outstanding obligations to prevent
 *      insolvency and restrict owner withdrawals to excess funds.
 *
 * Key features:
 * - Multi-asset bonding (stablecoins: USDC, USDT, DAI)
 * - Configurable discount rates (5-15%)
 * - Linear vesting over configurable periods
 * - Daily capacity limits to prevent manipulation
 * - Dynamic discount adjustment based on demand
 * - Solvency guarantees via totalXomOutstanding tracking
 * - Price change bounds (MAX_PRICE_CHANGE_BPS, MIN/MAX bounds)
 * - 6-hour cooldown on price updates to prevent manipulation
 *
 * IMPORTANT: The current implementation assumes all bonded assets are
 * worth $1 per unit (stablecoins). Do NOT add non-stablecoin assets
 * (ETH, AVAX, LP tokens) without first integrating per-asset price
 * feeds. See _normalizeToPrice() documentation and audit H-03.
 *
 * SECURITY: The owner address MUST be a multisig wallet (e.g., Gnosis
 * Safe) or a timelock controller -- NOT an externally owned account
 * (EOA). All admin functions (setXomPrice, addBondAsset, setTreasury,
 * updateBondTerms, setBondAssetEnabled, withdrawXom, depositXom,
 * pause, unpause) are protected by onlyOwner. A compromised EOA would
 * allow an attacker to manipulate bond pricing, redirect treasury
 * funds, and extract excess XOM. Use transferOwnership() to transfer
 * control to a multisig or timelock before mainnet deployment.
 *
 * Bonding Curve Formula:
 * xomOwed = (assetValue * PRICE_PRECISION) / discountedPrice
 * where:
 *   assetValue = amount normalized to 18 decimals (1:1 for stablecoins)
 *   discountedPrice = xomPrice * (10000 - discountBps) / 10000
 *   discountBps is in [500, 1500] (5% to 15% discount)
 *
 * Example: Bond 1000 USDC at $0.005 XOM price with 10% discount:
 *   assetValue = 1000e18
 *   discountedPrice = 5e15 * (10000 - 1000) / 10000 = 4.5e15
 *   xomOwed = 1000e18 * 1e18 / 4.5e15 = 222,222.22 XOM
 *
 * Relationship to Token Supply:
 * The bonding contract distributes XOM from its deposited balance.
 * It does NOT mint new tokens. The owner must deposit sufficient XOM
 * via depositXom() before users can bond. The totalXomOutstanding
 * tracker ensures the contract always holds enough XOM to satisfy
 * all outstanding bond obligations.
 *
 * Inspired by Olympus DAO bonding mechanism.
 */
contract OmniBonding is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ============ Structs ============

    /// @notice Configuration for each bondable asset
    /// @dev Packed for gas efficiency: asset (20) + enabled (1) + decimals (1)
    ///      fit in a single 32-byte slot
    struct BondTerms {
        /// @notice Asset contract (ERC20)
        IERC20 asset;
        /// @notice Whether this asset is enabled for bonding
        bool enabled;
        /// @notice Asset decimals for normalization
        uint8 decimals;
        /// @notice Discount in basis points (e.g., 1000 = 10%)
        uint256 discountBps;
        /// @notice Vesting period in seconds
        uint256 vestingPeriod;
        /// @notice Maximum bonds per day in asset terms
        uint256 dailyCapacity;
        /// @notice Amount bonded today
        uint256 dailyBonded;
        /// @notice Last capacity reset day (unix days)
        uint256 lastResetDay;
        /// @notice Total XOM distributed via this bond type
        uint256 totalXomDistributed;
        /// @notice Total asset received via this bond type
        uint256 totalAssetReceived;
    }

    /// @notice User's active bond position
    struct UserBond {
        /// @notice Total XOM owed to user
        uint256 xomOwed;
        /// @notice Timestamp when vesting ends
        uint256 vestingEnd;
        /// @notice Timestamp when vesting started
        uint256 vestingStart;
        /// @notice Amount already claimed
        uint256 claimed;
    }

    // ============ Constants ============

    /// @notice Basis points for percentage calculations (100% = 10000)
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Minimum discount allowed (5%)
    uint256 public constant MIN_DISCOUNT_BPS = 500;

    /// @notice Maximum discount allowed (15%)
    uint256 public constant MAX_DISCOUNT_BPS = 1_500;

    /// @notice Minimum vesting period (1 day)
    uint256 public constant MIN_VESTING_PERIOD = 1 days;

    /// @notice Maximum vesting period (30 days)
    uint256 public constant MAX_VESTING_PERIOD = 30 days;

    /// @notice Maximum number of bond assets (M-01: bounds claimAll loop)
    uint256 public constant MAX_BOND_ASSETS = 50;

    /// @notice Price precision for calculations
    uint256 private constant PRICE_PRECISION = 1e18;

    /// @notice Maximum price change per update (10% = 1000 bps)
    /// @dev Limits owner's ability to manipulate XOM price drastically
    ///      in a single transaction (H-02 fix)
    uint256 public constant MAX_PRICE_CHANGE_BPS = 1_000;

    /// @notice Minimum allowed XOM price ($0.0001 in 18 decimals)
    uint256 public constant MIN_XOM_PRICE = 1e14;

    /// @notice Maximum allowed XOM price ($100 in 18 decimals)
    uint256 public constant MAX_XOM_PRICE = 100e18;

    /// @notice Cooldown between price updates (6 hours)
    /// @dev Prevents multi-call price manipulation by requiring a
    ///      minimum interval between setXomPrice() calls. Without
    ///      this cooldown, the owner could make multiple 10% changes
    ///      in a single block, achieving up to ~65% price movement.
    uint256 public constant PRICE_COOLDOWN = 6 hours;

    // ============ Immutables ============

    /// @notice XOM token contract
    IERC20 public immutable XOM;

    // ============ State Variables ============

    /// @notice Treasury address receiving bonded assets
    address public treasury;

    /// @notice XOM price oracle address (for price-based calculations)
    address public priceOracle;

    /// @notice Fixed XOM price used when oracle is not set (18 decimals)
    uint256 public fixedXomPrice;

    /// @notice Timestamp of the last price update via setXomPrice()
    /// @dev Used to enforce PRICE_COOLDOWN between consecutive updates
    uint256 public lastPriceUpdateTime;

    /// @notice Bond terms by asset address
    mapping(address => BondTerms) public bondTerms;

    /// @notice User bonds by user => asset => bond
    mapping(address => mapping(address => UserBond)) public userBonds;

    /// @notice List of all supported bond assets
    address[] public bondAssets;

    /// @notice Total XOM distributed across all bonds
    uint256 public totalXomDistributed;

    /// @notice Total value received across all bonds (normalized to 18 decimals)
    uint256 public totalValueReceived;

    /// @notice Total XOM committed but not yet claimed across all bonds
    /// @dev Tracks outstanding obligations to ensure solvency. Incremented
    ///      on bond creation, decremented on claims.
    uint256 public totalXomOutstanding;

    // ============ Events ============

    /* solhint-disable gas-indexed-events */

    /// @notice Emitted when a new bond is created
    /// @param user User creating the bond
    /// @param asset Asset being bonded
    /// @param assetAmount Amount of asset bonded
    /// @param xomOwed Amount of XOM owed to user
    /// @param vestingEnd Timestamp when vesting completes
    event BondCreated(
        address indexed user,
        address indexed asset,
        uint256 assetAmount,
        uint256 xomOwed,
        uint256 vestingEnd
    );

    /// @notice Emitted when a user claims vested XOM
    /// @param user User claiming
    /// @param asset Asset the bond was for
    /// @param amount Amount of XOM claimed
    event BondClaimed(
        address indexed user,
        address indexed asset,
        uint256 amount
    );

    /// @notice Emitted when bond terms are updated
    /// @param asset Asset address
    /// @param discountBps New discount rate
    /// @param vestingPeriod New vesting period
    /// @param dailyCapacity New daily capacity
    event BondTermsUpdated(
        address indexed asset,
        uint256 discountBps,
        uint256 vestingPeriod,
        uint256 dailyCapacity
    );

    /// @notice Emitted when a new bond asset is added
    /// @param asset Asset address
    /// @param decimals Asset decimals
    event BondAssetAdded(
        address indexed asset,
        uint8 indexed decimals
    );

    /// @notice Emitted when XOM price is updated
    /// @param newPrice New fixed XOM price
    event XomPriceUpdated(uint256 indexed newPrice);

    /// @notice Emitted when excess XOM is withdrawn to treasury
    /// @param amount Amount of XOM withdrawn
    /// @param treasuryAddr Treasury address receiving the XOM
    event XomWithdrawn(
        uint256 indexed amount,
        address indexed treasuryAddr
    );

    /// @notice Emitted when a bond asset is enabled or disabled
    /// @param asset Asset address that was toggled
    /// @param enabled New enabled state (true = accepting bonds)
    event BondAssetEnabledChanged(
        address indexed asset,
        bool indexed enabled
    );

    /// @notice Emitted when treasury address is changed
    /// @param oldTreasury Previous treasury address
    /// @param newTreasury New treasury address
    event TreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );

    /// @notice Emitted when price oracle address is changed
    /// @param oldOracle Previous oracle address
    /// @param newOracle New oracle address
    event PriceOracleUpdated(
        address indexed oldOracle,
        address indexed newOracle
    );

    /// @notice Emitted when XOM is deposited for bond distribution
    /// @param depositor Address that deposited XOM
    /// @param amount Amount of XOM deposited
    event XomDeposited(
        address indexed depositor,
        uint256 amount
    );

    /// @notice Emitted when a non-XOM token is rescued from the contract
    /// @param token Token address rescued
    /// @param amount Amount rescued
    /// @param recipient Address receiving the rescued tokens
    event TokenRescued(
        address indexed token,
        uint256 amount,
        address indexed recipient
    );

    /* solhint-enable gas-indexed-events */

    // ============ Errors ============

    /// @notice Thrown when asset is not supported for bonding
    error AssetNotSupported();

    /// @notice Thrown when asset is disabled
    error AssetDisabled();

    /// @notice Thrown when daily capacity is exceeded
    error DailyCapacityExceeded();

    /// @notice Thrown when user already has an active bond for this asset
    error ActiveBondExists();

    /// @notice Thrown when user has no bond to claim
    error NoBondToClaim();

    /// @notice Thrown when there is nothing to claim yet
    error NothingToClaim();

    /// @notice Thrown when parameters are invalid
    error InvalidParameters();

    /// @notice Thrown when discount is out of range
    error InvalidDiscount();

    /// @notice Thrown when vesting period is out of range
    error InvalidVestingPeriod();

    /// @notice Thrown when asset is already added
    error AssetAlreadyAdded();

    /// @notice Thrown when XOM balance is insufficient for obligations
    error InsufficientXomBalance();

    /// @notice Thrown when price change exceeds MAX_PRICE_CHANGE_BPS
    /// @param oldPrice The current price
    /// @param newPrice The proposed new price
    error PriceChangeExceedsLimit(uint256 oldPrice, uint256 newPrice);

    /// @notice Thrown when price is outside the allowed bounds
    /// @param price The proposed price
    error PriceOutOfBounds(uint256 price);

    /// @notice Thrown when MAX_BOND_ASSETS limit is reached
    error TooManyAssets();

    /// @notice Thrown when actual transferred amount differs from expected
    ///         (fee-on-transfer protection)
    error TransferAmountMismatch();

    /// @notice Thrown when setXomPrice is called before PRICE_COOLDOWN
    ///         has elapsed since the last price update
    error PriceCooldownActive();

    /// @notice Thrown when rescueToken is called with XOM address
    error CannotRescueXom();

    // ============ Constructor ============

    /**
     * @notice Initialize the bonding contract
     * @param _xom XOM token address
     * @param _treasury Treasury address to receive bonded assets
     * @param _initialXomPrice Initial fixed XOM price
     *        (18 decimals, e.g., 5e15 = $0.005)
     */
    constructor(
        address _xom,
        address _treasury,
        uint256 _initialXomPrice
    ) Ownable(msg.sender) {
        if (_xom == address(0) || _treasury == address(0)) {
            revert InvalidParameters();
        }
        if (
            _initialXomPrice < MIN_XOM_PRICE
                || _initialXomPrice > MAX_XOM_PRICE
        ) {
            revert PriceOutOfBounds(_initialXomPrice);
        }

        XOM = IERC20(_xom);
        treasury = _treasury;
        fixedXomPrice = _initialXomPrice;
    }

    // ============ External Functions ============

    /**
     * @notice Add a new bondable asset to the bonding program
     * @dev Only stablecoin assets should be added (see contract-level
     *      NatSpec). The admin SHOULD be a multisig or timelock.
     *      Bounded by MAX_BOND_ASSETS (50) to limit claimAll() gas.
     * @param asset Asset contract address (must not be zero or
     *        already added)
     * @param decimals Asset decimals (must be <= 24)
     * @param discountBps Initial discount in basis points
     *        (MIN_DISCOUNT_BPS to MAX_DISCOUNT_BPS)
     * @param vestingPeriod Vesting period in seconds
     *        (MIN_VESTING_PERIOD to MAX_VESTING_PERIOD)
     * @param dailyCapacity Maximum daily bonding capacity
     *        (in asset terms)
     */
    function addBondAsset(
        address asset,
        uint8 decimals,
        uint256 discountBps,
        uint256 vestingPeriod,
        uint256 dailyCapacity
    ) external onlyOwner {
        if (asset == address(0)) revert InvalidParameters();
        // solhint-disable-next-line gas-strict-inequalities
        if (bondAssets.length >= MAX_BOND_ASSETS) {
            revert TooManyAssets();
        }
        if (
            bondTerms[asset].asset != IERC20(address(0))
        ) revert AssetAlreadyAdded();
        if (
            discountBps < MIN_DISCOUNT_BPS
                || discountBps > MAX_DISCOUNT_BPS
        ) {
            revert InvalidDiscount();
        }
        if (
            vestingPeriod < MIN_VESTING_PERIOD
                || vestingPeriod > MAX_VESTING_PERIOD
        ) {
            revert InvalidVestingPeriod();
        }
        // L-03: Validate decimals (no real token exceeds 24)
        if (decimals > 24) revert InvalidParameters();

        // solhint-disable-next-line not-rely-on-time
        uint256 resetDay = block.timestamp / 1 days;

        bondTerms[asset] = BondTerms({
            asset: IERC20(asset),
            enabled: true,
            decimals: decimals,
            discountBps: discountBps,
            vestingPeriod: vestingPeriod,
            dailyCapacity: dailyCapacity,
            dailyBonded: 0,
            lastResetDay: resetDay,
            totalXomDistributed: 0,
            totalAssetReceived: 0
        });

        bondAssets.push(asset);

        emit BondAssetAdded(asset, decimals);
        emit BondTermsUpdated(
            asset, discountBps, vestingPeriod, dailyCapacity
        );
    }

    /**
     * @notice Update bond terms for an existing asset
     * @dev Does not affect existing active bonds, only future ones.
     *      The admin SHOULD be a multisig or timelock.
     * @param asset Asset address (must already be added)
     * @param discountBps New discount in basis points
     *        (MIN_DISCOUNT_BPS to MAX_DISCOUNT_BPS)
     * @param vestingPeriod New vesting period in seconds
     *        (MIN_VESTING_PERIOD to MAX_VESTING_PERIOD)
     * @param dailyCapacity New daily capacity in asset terms
     */
    function updateBondTerms(
        address asset,
        uint256 discountBps,
        uint256 vestingPeriod,
        uint256 dailyCapacity
    ) external onlyOwner {
        BondTerms storage terms = bondTerms[asset];
        if (address(terms.asset) == address(0)) {
            revert AssetNotSupported();
        }
        if (
            discountBps < MIN_DISCOUNT_BPS
                || discountBps > MAX_DISCOUNT_BPS
        ) {
            revert InvalidDiscount();
        }
        if (
            vestingPeriod < MIN_VESTING_PERIOD
                || vestingPeriod > MAX_VESTING_PERIOD
        ) {
            revert InvalidVestingPeriod();
        }

        terms.discountBps = discountBps;
        terms.vestingPeriod = vestingPeriod;
        terms.dailyCapacity = dailyCapacity;

        emit BondTermsUpdated(
            asset, discountBps, vestingPeriod, dailyCapacity
        );
    }

    /**
     * @notice Enable or disable a bond asset
     * @dev Emits BondAssetEnabledChanged for off-chain monitoring.
     *      The admin (owner) SHOULD be a multisig or timelock to
     *      prevent a single compromised key from disabling all assets.
     * @param asset Asset address
     * @param enabled Whether to enable (true) or disable (false)
     */
    function setBondAssetEnabled(
        address asset,
        bool enabled
    ) external onlyOwner {
        BondTerms storage terms = bondTerms[asset];
        if (address(terms.asset) == address(0)) {
            revert AssetNotSupported();
        }
        terms.enabled = enabled;
        emit BondAssetEnabledChanged(asset, enabled);
    }

    /**
     * @notice Create a bond by depositing an asset
     * @dev Checks solvency against all outstanding obligations
     *      before creating the bond. Increments totalXomOutstanding.
     * @param asset Asset to bond
     * @param amount Amount of asset to bond
     * @return xomOwed Amount of XOM owed to user
     */
    function bond(
        address asset,
        uint256 amount
    ) external nonReentrant whenNotPaused returns (uint256 xomOwed) {
        // L-02: Reject zero-amount bonds
        if (amount == 0) revert InvalidParameters();

        BondTerms storage terms = _validateBondAsset(
            asset, amount
        );

        // Check for existing active bond
        UserBond storage existingBond =
            userBonds[msg.sender][asset];
        if (
            existingBond.xomOwed > 0
                && existingBond.claimed < existingBond.xomOwed
        ) {
            revert ActiveBondExists();
        }

        // Calculate XOM owed with discount
        uint256 assetValue = _normalizeToPrice(
            amount, terms.decimals
        );
        uint256 xomPrice = getXomPrice();
        uint256 discountedPrice =
            (xomPrice * (BASIS_POINTS - terms.discountBps))
                / BASIS_POINTS;
        xomOwed =
            (assetValue * PRICE_PRECISION) / discountedPrice;

        // L-02: Reject bonds that produce zero XOM (rounding)
        if (xomOwed == 0) revert InvalidParameters();

        // Check contract has enough XOM for all obligations
        // including this new bond (C-01 fix)
        if (
            XOM.balanceOf(address(this))
                < totalXomOutstanding + xomOwed
        ) {
            revert InsufficientXomBalance();
        }

        // M-02: Transfer asset to treasury with fee-on-transfer protection
        uint256 treasuryBalBefore =
            terms.asset.balanceOf(treasury);
        terms.asset.safeTransferFrom(
            msg.sender, treasury, amount
        );
        uint256 actualReceived =
            terms.asset.balanceOf(treasury) - treasuryBalBefore;
        if (actualReceived != amount) {
            revert TransferAmountMismatch();
        }

        // Create bond
        // solhint-disable-next-line not-rely-on-time
        uint256 vestingEnd = block.timestamp + terms.vestingPeriod;
        userBonds[msg.sender][asset] = UserBond({
            xomOwed: xomOwed,
            // solhint-disable-next-line not-rely-on-time
            vestingStart: block.timestamp,
            vestingEnd: vestingEnd,
            claimed: 0
        });

        // Update state
        terms.dailyBonded += amount;
        terms.totalXomDistributed += xomOwed;
        terms.totalAssetReceived += amount;
        totalXomDistributed += xomOwed;
        totalValueReceived += assetValue;
        totalXomOutstanding += xomOwed;

        emit BondCreated(
            msg.sender, asset, amount, xomOwed, vestingEnd
        );

        return xomOwed;
    }

    /**
     * @notice Claim vested XOM from a bond
     * @dev Decrements totalXomOutstanding by the claimed amount
     * @param asset Asset the bond was created with
     * @return claimed Amount of XOM claimed
     */
    function claim(
        address asset
    ) external nonReentrant returns (uint256 claimed) {
        UserBond storage userBond = userBonds[msg.sender][asset];
        if (userBond.xomOwed == 0) revert NoBondToClaim();

        claimed = _calculateClaimable(userBond);
        if (claimed == 0) revert NothingToClaim();

        userBond.claimed += claimed;
        totalXomOutstanding -= claimed;

        // M-03: Clean up fully-claimed bond to free storage
        // and allow re-bonding without friction
        if (userBond.claimed == userBond.xomOwed) {
            delete userBonds[msg.sender][asset];
        }

        XOM.safeTransfer(msg.sender, claimed);

        emit BondClaimed(msg.sender, asset, claimed);

        return claimed;
    }

    /**
     * @notice Claim vested XOM from all bonds
     * @dev Decrements totalXomOutstanding by the total claimed
     * @return totalClaimed Total amount of XOM claimed
     */
    function claimAll()
        external
        nonReentrant
        returns (uint256 totalClaimed)
    {
        for (uint256 i = 0; i < bondAssets.length; ++i) {
            address asset = bondAssets[i];
            UserBond storage userBond =
                userBonds[msg.sender][asset];

            if (userBond.xomOwed > 0) {
                uint256 claimable = _calculateClaimable(
                    userBond
                );
                if (claimable > 0) {
                    userBond.claimed += claimable;
                    totalClaimed += claimable;

                    // M-03: Clean up fully-claimed bonds
                    if (
                        userBond.claimed == userBond.xomOwed
                    ) {
                        delete userBonds[msg.sender][asset];
                    }

                    emit BondClaimed(
                        msg.sender, asset, claimable
                    );
                }
            }
        }

        if (totalClaimed == 0) revert NothingToClaim();
        totalXomOutstanding -= totalClaimed;
        XOM.safeTransfer(msg.sender, totalClaimed);

        return totalClaimed;
    }

    /**
     * @notice Update fixed XOM price with bounds, rate-of-change
     *         limits, and cooldown
     * @dev Prevents price manipulation by enforcing:
     *      1. Price must be within [MIN_XOM_PRICE, MAX_XOM_PRICE]
     *      2. Price change cannot exceed MAX_PRICE_CHANGE_BPS (10%)
     *         per update
     *      3. A PRICE_COOLDOWN (6 hours) must elapse between updates
     *      Without the cooldown, an owner (or batch contract) could
     *      make 10 sequential calls, changing price by ~65% in one
     *      block. With the cooldown, effective max change is ~10%
     *      per 6 hours. The admin SHOULD be a multisig or timelock.
     * @param newPrice New price in 18 decimals
     */
    function setXomPrice(uint256 newPrice) external onlyOwner {
        if (newPrice < MIN_XOM_PRICE || newPrice > MAX_XOM_PRICE) {
            revert PriceOutOfBounds(newPrice);
        }

        // Enforce cooldown between price updates
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < lastPriceUpdateTime + PRICE_COOLDOWN) {
            revert PriceCooldownActive();
        }

        uint256 oldPrice = fixedXomPrice;

        // Enforce maximum rate of change per update
        uint256 priceDelta = newPrice > oldPrice
            ? newPrice - oldPrice
            : oldPrice - newPrice;
        uint256 maxDelta =
            (oldPrice * MAX_PRICE_CHANGE_BPS) / BASIS_POINTS;
        if (priceDelta > maxDelta) {
            revert PriceChangeExceedsLimit(oldPrice, newPrice);
        }

        fixedXomPrice = newPrice;
        // solhint-disable-next-line not-rely-on-time
        lastPriceUpdateTime = block.timestamp;
        emit XomPriceUpdated(newPrice);
    }

    /**
     * @notice Update treasury address
     * @dev Rejects zero address and self-reference. If treasury is
     *      set to this contract, bonded assets would be trapped with
     *      no recovery mechanism. The admin SHOULD be a multisig.
     * @param _treasury New treasury address (must not be zero or this
     *        contract)
     */
    function setTreasury(
        address _treasury
    ) external onlyOwner {
        if (_treasury == address(0)) revert InvalidParameters();
        if (_treasury == address(this)) revert InvalidParameters();
        address oldTreasury = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    /**
     * @notice Update price oracle address
     * @dev The oracle is stored for future integration but is not
     *      currently used by getXomPrice(). When oracle integration
     *      is ready, getXomPrice() will be updated to query it.
     *      The admin SHOULD be a multisig or timelock.
     * @param _priceOracle New oracle address (must not be zero)
     */
    function setPriceOracle(
        address _priceOracle
    ) external onlyOwner {
        if (_priceOracle == address(0)) {
            revert InvalidParameters();
        }
        address oldOracle = priceOracle;
        priceOracle = _priceOracle;
        emit PriceOracleUpdated(oldOracle, _priceOracle);
    }

    /**
     * @notice Deposit XOM for bond distribution
     * @dev Uses balance-before/after pattern to verify actual received
     *      amount matches expected. This protects the solvency
     *      invariant if XOM ever implements fee-on-transfer.
     * @param amount Amount of XOM to deposit (must match actual
     *        received)
     */
    function depositXom(uint256 amount) external onlyOwner {
        uint256 balBefore = XOM.balanceOf(address(this));
        XOM.safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualReceived =
            XOM.balanceOf(address(this)) - balBefore;
        if (actualReceived != amount) {
            revert TransferAmountMismatch();
        }
        emit XomDeposited(msg.sender, amount);
    }

    /**
     * @notice Withdraw excess XOM above outstanding obligations
     * @dev Only allows withdrawal of XOM not committed to bond
     *      holders, preventing rug pulls. The solvency invariant
     *      balance >= totalXomOutstanding is maintained. Sends excess
     *      to the treasury. The admin SHOULD be a multisig.
     * @param amount Amount to withdraw (must be <= excess above
     *        totalXomOutstanding)
     */
    function withdrawXom(uint256 amount) external onlyOwner {
        uint256 balance = XOM.balanceOf(address(this));
        uint256 excess = balance - totalXomOutstanding;
        if (amount > excess) revert InsufficientXomBalance();
        XOM.safeTransfer(treasury, amount);
        emit XomWithdrawn(amount, treasury);
    }

    /**
     * @notice Pause bonding (emergency only)
     * @dev Only pauses bond(), not claim() or claimAll(). Users can
     *      always claim vested tokens even when paused. The admin
     *      SHOULD be a multisig or timelock.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause bonding
     * @dev Only callable by the contract owner (should be multisig).
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Rescue accidentally sent ERC20 tokens (not XOM)
     * @dev Users may accidentally send tokens directly to this contract
     *      via transfer(). Only non-XOM tokens can be rescued to prevent
     *      violation of the solvency invariant. Rescued tokens are sent
     *      to the treasury. The admin SHOULD be a multisig or timelock.
     * @param token Token address to rescue (must not be XOM)
     * @param amount Amount of tokens to rescue
     */
    function rescueToken(
        address token,
        uint256 amount
    ) external onlyOwner {
        if (token == address(XOM)) revert CannotRescueXom();
        IERC20(token).safeTransfer(treasury, amount);
        emit TokenRescued(token, amount, treasury);
    }

    // ============ View Functions ============

    /**
     * @notice Get claimable amount for a user's bond
     * @param user User address
     * @param asset Asset address
     * @return claimable Amount of XOM claimable
     */
    function getClaimable(
        address user,
        address asset
    ) external view returns (uint256 claimable) {
        UserBond storage userBond = userBonds[user][asset];
        return _calculateClaimable(userBond);
    }

    /**
     * @notice Get bond information for a user
     * @param user User address
     * @param asset Asset address
     * @return xomOwed Total XOM owed
     * @return claimed Amount already claimed
     * @return claimable Amount currently claimable
     * @return vestingEnd Vesting end timestamp
     */
    function getBondInfo(
        address user,
        address asset
    )
        external
        view
        returns (
            uint256 xomOwed,
            uint256 claimed,
            uint256 claimable,
            uint256 vestingEnd
        )
    {
        UserBond storage userBond = userBonds[user][asset];
        return (
            userBond.xomOwed,
            userBond.claimed,
            _calculateClaimable(userBond),
            userBond.vestingEnd
        );
    }

    /**
     * @notice Get bond terms for an asset
     * @param asset Asset address
     * @return enabled Whether bonding is enabled
     * @return discountBps Current discount rate
     * @return vestingPeriod Vesting period in seconds
     * @return dailyCapacity Daily capacity
     * @return dailyRemaining Remaining capacity today
     */
    function getBondTerms(
        address asset
    )
        external
        view
        returns (
            bool enabled,
            uint256 discountBps,
            uint256 vestingPeriod,
            uint256 dailyCapacity,
            uint256 dailyRemaining
        )
    {
        BondTerms storage terms = bondTerms[asset];
        // solhint-disable-next-line not-rely-on-time
        uint256 currentDay = block.timestamp / 1 days;
        uint256 bonded = currentDay > terms.lastResetDay
            ? 0
            : terms.dailyBonded;

        return (
            terms.enabled,
            terms.discountBps,
            terms.vestingPeriod,
            terms.dailyCapacity,
            terms.dailyCapacity > bonded
                ? terms.dailyCapacity - bonded
                : 0
        );
    }

    /**
     * @notice Calculate expected XOM output for a bond
     * @param asset Asset to bond
     * @param amount Amount of asset
     * @return xomOut Expected XOM output
     * @return effectivePrice Effective XOM price after discount
     */
    function calculateBondOutput(
        address asset,
        uint256 amount
    )
        external
        view
        returns (uint256 xomOut, uint256 effectivePrice)
    {
        BondTerms storage terms = bondTerms[asset];
        if (address(terms.asset) == address(0)) {
            return (0, 0);
        }

        uint256 assetValue = _normalizeToPrice(
            amount, terms.decimals
        );
        uint256 xomPrice = getXomPrice();
        effectivePrice =
            (xomPrice * (BASIS_POINTS - terms.discountBps))
                / BASIS_POINTS;
        xomOut =
            (assetValue * PRICE_PRECISION) / effectivePrice;

        return (xomOut, effectivePrice);
    }

    /**
     * @notice Get list of all bond assets
     * @return assets Array of asset addresses
     */
    function getBondAssets()
        external
        view
        returns (address[] memory assets)
    {
        return bondAssets;
    }

    /**
     * @notice Get number of bond assets
     * @return count Number of bond assets
     */
    function getBondAssetCount()
        external
        view
        returns (uint256 count)
    {
        return bondAssets.length;
    }

    /**
     * @notice Get aggregated protocol statistics
     * @dev Provides a single-call summary of key protocol metrics
     *      for frontend display and monitoring dashboards
     * @return distributed Lifetime XOM distributed via bonds
     * @return outstanding XOM currently owed to bond holders
     * @return valueReceived Lifetime value of bonded assets
     *         (18 decimals)
     * @return assetCount Number of configured bond assets
     */
    function getProtocolStats()
        external
        view
        returns (
            uint256 distributed,
            uint256 outstanding,
            uint256 valueReceived,
            uint256 assetCount
        )
    {
        return (
            totalXomDistributed,
            totalXomOutstanding,
            totalValueReceived,
            bondAssets.length
        );
    }

    // ============ Public View Functions ============

    /**
     * @notice Get current XOM price
     * @dev Returns the fixed price. When a price oracle is
     *      integrated, this function will query it instead.
     * @return price XOM price in 18 decimals
     */
    function getXomPrice()
        public
        view
        returns (uint256 price)
    {
        return fixedXomPrice;
    }

    // ============ Internal Functions ============

    /**
     * @notice Validate bond asset and enforce daily capacity limit
     * @dev Resets daily counter on new day; reverts if asset is
     *      unsupported, disabled, or capacity exceeded.
     * @param asset Asset address to validate
     * @param amount Bond amount in asset terms
     * @return terms Storage pointer to the validated BondTerms
     */
    function _validateBondAsset(
        address asset,
        uint256 amount
    ) internal returns (BondTerms storage terms) {
        terms = bondTerms[asset];
        if (address(terms.asset) == address(0)) {
            revert AssetNotSupported();
        }
        if (!terms.enabled) revert AssetDisabled();

        // Reset daily capacity if new day
        // solhint-disable-next-line not-rely-on-time
        uint256 currentDay = block.timestamp / 1 days;
        if (currentDay > terms.lastResetDay) {
            terms.dailyBonded = 0;
            terms.lastResetDay = currentDay;
        }

        // Check daily capacity
        if (terms.dailyBonded + amount > terms.dailyCapacity) {
            revert DailyCapacityExceeded();
        }

        return terms;
    }

    /**
     * @notice Calculate claimable XOM from a bond
     * @param userBond User's bond struct
     * @return claimable Amount claimable
     */
    function _calculateClaimable(
        UserBond storage userBond
    ) internal view returns (uint256 claimable) {
        if (userBond.xomOwed == 0) return 0;

        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp >= userBond.vestingEnd) {
            // Fully vested
            return userBond.xomOwed - userBond.claimed;
        }

        // Linear vesting calculation
        // solhint-disable-next-line not-rely-on-time
        uint256 elapsed = block.timestamp - userBond.vestingStart;
        uint256 vestingDuration =
            userBond.vestingEnd - userBond.vestingStart;
        uint256 vested =
            (userBond.xomOwed * elapsed) / vestingDuration;

        return vested > userBond.claimed
            ? vested - userBond.claimed
            : 0;
    }

    /**
     * @notice Normalize asset amount to 18 decimal price value
     * @dev IMPORTANT: This function performs DECIMAL NORMALIZATION ONLY.
     *      It does NOT apply any exchange rate. The implicit assumption is
     *      that 1 unit of the bonded asset equals $1 USD. This is correct
     *      for stablecoins (USDC, USDT, DAI) but NOT for volatile assets
     *      (ETH, AVAX, LP tokens). Non-stablecoin assets require a per-asset
     *      price feed in BondTerms to produce correct XOM output. Until
     *      per-asset oracle integration is implemented, ONLY add stablecoins
     *      via addBondAsset(). See audit report H-03.
     *
     *      Example: USDC (6 decimals), $100 USDC = 100e6 -> 100e18
     * @param amount Asset amount in native decimals
     * @param decimals Asset decimals (must be <= 24)
     * @return normalized Amount normalized to 18 decimals
     */
    function _normalizeToPrice(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256 normalized) {
        if (decimals < 18) {
            return amount * (10 ** (18 - decimals));
        } else if (decimals > 18) {
            return amount / (10 ** (decimals - 18));
        }
        return amount;
    }
}
