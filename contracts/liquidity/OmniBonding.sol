// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title OmniBonding
 * @author OmniCoin Development Team
 * @notice Protocol Owned Liquidity via discounted XOM bond offerings
 * @dev Allows users to exchange assets (USDC, ETH, LP tokens) for discounted XOM
 *      with linear vesting. Protocol permanently owns the bonded assets.
 *
 * Key features:
 * - Multi-asset bonding (USDC, ETH, LP tokens, AVAX)
 * - Configurable discount rates (5-15%)
 * - Linear vesting over configurable periods
 * - Daily capacity limits to prevent manipulation
 * - Dynamic discount adjustment based on demand
 *
 * Inspired by Olympus DAO bonding mechanism.
 */
contract OmniBonding is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

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

    /// @notice Price precision for calculations
    uint256 private constant PRICE_PRECISION = 1e18;

    // ============ Immutables ============

    /// @notice XOM token contract
    IERC20 public immutable xom;

    // ============ Structs ============

    /// @notice Configuration for each bondable asset
    struct BondTerms {
        /// @notice Whether this asset is enabled for bonding
        bool enabled;
        /// @notice Asset contract (ERC20)
        IERC20 asset;
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

    // ============ State Variables ============

    /// @notice Treasury address receiving bonded assets
    address public treasury;

    /// @notice XOM price oracle address (for price-based calculations)
    address public priceOracle;

    /// @notice Fixed XOM price used when oracle is not set (18 decimals)
    uint256 public fixedXomPrice;

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

    // ============ Events ============

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
        uint256 indexed xomOwed,
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
    event BondAssetAdded(address indexed asset, uint8 decimals);

    /// @notice Emitted when XOM price is updated
    /// @param newPrice New fixed XOM price
    event XomPriceUpdated(uint256 newPrice);

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

    /// @notice Thrown when XOM balance is insufficient
    error InsufficientXomBalance();

    // ============ Constructor ============

    /**
     * @notice Initialize the bonding contract
     * @param _xom XOM token address
     * @param _treasury Treasury address to receive bonded assets
     * @param _initialXomPrice Initial fixed XOM price (18 decimals, e.g., 5e15 = $0.005)
     */
    constructor(
        address _xom,
        address _treasury,
        uint256 _initialXomPrice
    ) Ownable(msg.sender) {
        if (_xom == address(0) || _treasury == address(0)) {
            revert InvalidParameters();
        }
        if (_initialXomPrice == 0) revert InvalidParameters();

        xom = IERC20(_xom);
        treasury = _treasury;
        fixedXomPrice = _initialXomPrice;
    }

    // ============ External Functions ============

    /**
     * @notice Add a new bondable asset
     * @param asset Asset contract address
     * @param decimals Asset decimals
     * @param discountBps Initial discount in basis points
     * @param vestingPeriod Vesting period in seconds
     * @param dailyCapacity Maximum daily bonding capacity (in asset terms)
     */
    function addBondAsset(
        address asset,
        uint8 decimals,
        uint256 discountBps,
        uint256 vestingPeriod,
        uint256 dailyCapacity
    ) external onlyOwner {
        if (asset == address(0)) revert InvalidParameters();
        if (bondTerms[asset].asset != IERC20(address(0))) revert AssetAlreadyAdded();
        if (discountBps < MIN_DISCOUNT_BPS || discountBps > MAX_DISCOUNT_BPS) {
            revert InvalidDiscount();
        }
        if (vestingPeriod < MIN_VESTING_PERIOD || vestingPeriod > MAX_VESTING_PERIOD) {
            revert InvalidVestingPeriod();
        }

        bondTerms[asset] = BondTerms({
            enabled: true,
            asset: IERC20(asset),
            decimals: decimals,
            discountBps: discountBps,
            vestingPeriod: vestingPeriod,
            dailyCapacity: dailyCapacity,
            dailyBonded: 0,
            lastResetDay: block.timestamp / 1 days,
            totalXomDistributed: 0,
            totalAssetReceived: 0
        });

        bondAssets.push(asset);

        emit BondAssetAdded(asset, decimals);
        emit BondTermsUpdated(asset, discountBps, vestingPeriod, dailyCapacity);
    }

    /**
     * @notice Update bond terms for an existing asset
     * @param asset Asset address
     * @param discountBps New discount in basis points
     * @param vestingPeriod New vesting period
     * @param dailyCapacity New daily capacity
     */
    function updateBondTerms(
        address asset,
        uint256 discountBps,
        uint256 vestingPeriod,
        uint256 dailyCapacity
    ) external onlyOwner {
        BondTerms storage terms = bondTerms[asset];
        if (address(terms.asset) == address(0)) revert AssetNotSupported();
        if (discountBps < MIN_DISCOUNT_BPS || discountBps > MAX_DISCOUNT_BPS) {
            revert InvalidDiscount();
        }
        if (vestingPeriod < MIN_VESTING_PERIOD || vestingPeriod > MAX_VESTING_PERIOD) {
            revert InvalidVestingPeriod();
        }

        terms.discountBps = discountBps;
        terms.vestingPeriod = vestingPeriod;
        terms.dailyCapacity = dailyCapacity;

        emit BondTermsUpdated(asset, discountBps, vestingPeriod, dailyCapacity);
    }

    /**
     * @notice Enable or disable a bond asset
     * @param asset Asset address
     * @param enabled Whether to enable
     */
    function setBondAssetEnabled(address asset, bool enabled) external onlyOwner {
        BondTerms storage terms = bondTerms[asset];
        if (address(terms.asset) == address(0)) revert AssetNotSupported();
        terms.enabled = enabled;
    }

    /**
     * @notice Create a bond by depositing an asset
     * @param asset Asset to bond
     * @param amount Amount of asset to bond
     * @return xomOwed Amount of XOM owed to user
     */
    function bond(
        address asset,
        uint256 amount
    ) external nonReentrant whenNotPaused returns (uint256 xomOwed) {
        BondTerms storage terms = bondTerms[asset];
        if (address(terms.asset) == address(0)) revert AssetNotSupported();
        if (!terms.enabled) revert AssetDisabled();

        // Check for existing active bond
        UserBond storage existingBond = userBonds[msg.sender][asset];
        // solhint-disable-next-line not-rely-on-time
        if (existingBond.xomOwed > 0 && existingBond.claimed < existingBond.xomOwed) {
            revert ActiveBondExists();
        }

        // Reset daily capacity if new day
        uint256 currentDay = block.timestamp / 1 days;
        if (currentDay > terms.lastResetDay) {
            terms.dailyBonded = 0;
            terms.lastResetDay = currentDay;
        }

        // Check daily capacity
        if (terms.dailyBonded + amount > terms.dailyCapacity) {
            revert DailyCapacityExceeded();
        }

        // Calculate XOM owed with discount
        uint256 assetValue = _normalizeToPrice(amount, terms.decimals);
        uint256 xomPrice = getXomPrice();
        uint256 discountedPrice = (xomPrice * (BASIS_POINTS - terms.discountBps)) /
            BASIS_POINTS;
        xomOwed = (assetValue * PRICE_PRECISION) / discountedPrice;

        // Check contract has enough XOM
        if (xom.balanceOf(address(this)) < xomOwed) revert InsufficientXomBalance();

        // Transfer asset to treasury
        terms.asset.safeTransferFrom(msg.sender, treasury, amount);

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

        emit BondCreated(msg.sender, asset, amount, xomOwed, vestingEnd);

        return xomOwed;
    }

    /**
     * @notice Claim vested XOM from a bond
     * @param asset Asset the bond was created with
     * @return claimed Amount of XOM claimed
     */
    function claim(address asset) external nonReentrant returns (uint256 claimed) {
        UserBond storage userBond = userBonds[msg.sender][asset];
        if (userBond.xomOwed == 0) revert NoBondToClaim();

        claimed = _calculateClaimable(userBond);
        if (claimed == 0) revert NothingToClaim();

        userBond.claimed += claimed;
        xom.safeTransfer(msg.sender, claimed);

        emit BondClaimed(msg.sender, asset, claimed);

        return claimed;
    }

    /**
     * @notice Claim vested XOM from all bonds
     * @return totalClaimed Total amount of XOM claimed
     */
    function claimAll() external nonReentrant returns (uint256 totalClaimed) {
        for (uint256 i = 0; i < bondAssets.length; i++) {
            address asset = bondAssets[i];
            UserBond storage userBond = userBonds[msg.sender][asset];

            if (userBond.xomOwed > 0) {
                uint256 claimable = _calculateClaimable(userBond);
                if (claimable > 0) {
                    userBond.claimed += claimable;
                    totalClaimed += claimable;
                    emit BondClaimed(msg.sender, asset, claimable);
                }
            }
        }

        if (totalClaimed == 0) revert NothingToClaim();
        xom.safeTransfer(msg.sender, totalClaimed);

        return totalClaimed;
    }

    /**
     * @notice Update fixed XOM price
     * @param newPrice New price in 18 decimals
     */
    function setXomPrice(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert InvalidParameters();
        fixedXomPrice = newPrice;
        emit XomPriceUpdated(newPrice);
    }

    /**
     * @notice Update treasury address
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidParameters();
        treasury = _treasury;
    }

    /**
     * @notice Update price oracle address
     * @param _priceOracle New oracle address
     */
    function setPriceOracle(address _priceOracle) external onlyOwner {
        if (_priceOracle == address(0)) revert InvalidParameters();
        priceOracle = _priceOracle;
    }

    /**
     * @notice Deposit XOM for bond distribution
     * @param amount Amount of XOM to deposit
     */
    function depositXom(uint256 amount) external onlyOwner {
        xom.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraw excess XOM (emergency only)
     * @param amount Amount to withdraw
     */
    function withdrawXom(uint256 amount) external onlyOwner {
        xom.safeTransfer(treasury, amount);
    }

    /**
     * @notice Pause bonding
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause bonding
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ View Functions ============

    /**
     * @notice Get current XOM price
     * @return price XOM price in 18 decimals
     */
    function getXomPrice() public view returns (uint256 price) {
        // TODO: Integrate with price oracle when available
        // For now, use fixed price
        return fixedXomPrice;
    }

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
        uint256 currentDay = block.timestamp / 1 days;
        uint256 bonded = currentDay > terms.lastResetDay ? 0 : terms.dailyBonded;

        return (
            terms.enabled,
            terms.discountBps,
            terms.vestingPeriod,
            terms.dailyCapacity,
            terms.dailyCapacity > bonded ? terms.dailyCapacity - bonded : 0
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
    ) external view returns (uint256 xomOut, uint256 effectivePrice) {
        BondTerms storage terms = bondTerms[asset];
        if (address(terms.asset) == address(0)) return (0, 0);

        uint256 assetValue = _normalizeToPrice(amount, terms.decimals);
        uint256 xomPrice = getXomPrice();
        effectivePrice = (xomPrice * (BASIS_POINTS - terms.discountBps)) / BASIS_POINTS;
        xomOut = (assetValue * PRICE_PRECISION) / effectivePrice;

        return (xomOut, effectivePrice);
    }

    /**
     * @notice Get list of all bond assets
     * @return assets Array of asset addresses
     */
    function getBondAssets() external view returns (address[] memory assets) {
        return bondAssets;
    }

    /**
     * @notice Get number of bond assets
     * @return count Number of bond assets
     */
    function getBondAssetCount() external view returns (uint256 count) {
        return bondAssets.length;
    }

    // ============ Internal Functions ============

    /**
     * @notice Calculate claimable XOM from a bond
     * @param userBond User's bond struct
     * @return claimable Amount claimable
     */
    function _calculateClaimable(
        UserBond storage userBond
    ) internal view returns (uint256 claimable) {
        if (userBond.xomOwed == 0) return 0;

        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp >= userBond.vestingEnd) {
            // Fully vested
            return userBond.xomOwed - userBond.claimed;
        }

        // Linear vesting
        // solhint-disable-next-line not-rely-on-time
        uint256 elapsed = block.timestamp - userBond.vestingStart;
        uint256 vestingDuration = userBond.vestingEnd - userBond.vestingStart;
        uint256 vested = (userBond.xomOwed * elapsed) / vestingDuration;

        return vested > userBond.claimed ? vested - userBond.claimed : 0;
    }

    /**
     * @notice Normalize asset amount to 18 decimal price value
     * @dev For USDC (6 decimals), $100 USDC = 100e6 → 100e18
     * @param amount Asset amount
     * @param decimals Asset decimals
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
