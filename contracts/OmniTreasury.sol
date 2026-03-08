// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

// ════════════════════════════════════════════════════════════════════════
//                          OmniTreasury
// ════════════════════════════════════════════════════════════════════════

/**
 * @title OmniTreasury
 * @author OmniCoin Development Team
 * @notice Protocol-Owned Liquidity (POL) wallet that receives the 10%
 *         protocol share from every fee-distributing contract in the
 *         OmniBazaar ecosystem.
 * @dev Immutable (non-upgradeable) treasury controlled via AccessControl
 *      roles. During the Pioneer Phase the deployer holds all roles;
 *      once OmniTimelockController and EmergencyGuardian are live the
 *      deployer renounces every role.
 *
 *      Accepts native XOM, ERC-20, ERC-721, and ERC-1155 tokens.
 *      All outbound transfers require GOVERNANCE_ROLE and are blocked
 *      while the contract is paused.
 */
contract OmniTreasury is
    AccessControl,
    ReentrancyGuard,
    Pausable,
    ERC721Holder,
    ERC1155Holder
{
    using SafeERC20 for IERC20;

    // ─────────────────────────── Constants ───────────────────────────

    /// @notice Role that can transfer assets, approve spenders, and
    ///         execute arbitrary calls through the treasury.
    bytes32 public constant GOVERNANCE_ROLE =
        keccak256("GOVERNANCE_ROLE");

    /// @notice Role that can pause and unpause the contract in an
    ///         emergency.
    bytes32 public constant GUARDIAN_ROLE =
        keccak256("GUARDIAN_ROLE");

    /// @notice Maximum number of calls allowed in a single
    ///         `executeBatch` invocation.
    uint256 public constant MAX_BATCH_SIZE = 64;

    // ──────────────────────────── Events ─────────────────────────────

    /// @notice Emitted when native XOM is received via `receive()`.
    /// @param sender The address that sent XOM.
    /// @param amount The amount of XOM received (in wei).
    event NativeReceived(address indexed sender, uint256 indexed amount);

    /// @notice Emitted when an ERC-20 token is transferred out.
    /// @param token  The ERC-20 token address.
    /// @param to     The recipient address.
    /// @param amount The amount transferred.
    event TokenTransferred(
        address indexed token,
        address indexed to,
        uint256 indexed amount
    );

    /// @notice Emitted when native XOM is transferred out.
    /// @param to     The recipient address.
    /// @param amount The amount of XOM sent (in wei).
    event NativeTransferred(address indexed to, uint256 indexed amount);

    /// @notice Emitted when an ERC-20 spending allowance is set.
    /// @param token   The ERC-20 token address.
    /// @param spender The approved spender address.
    /// @param amount  The approved amount.
    event TokenApproved(
        address indexed token,
        address indexed spender,
        uint256 indexed amount
    );

    /// @notice Emitted when an ERC-721 NFT is transferred out.
    /// @param nft     The ERC-721 contract address.
    /// @param to      The recipient address.
    /// @param tokenId The NFT token ID.
    event NFTTransferred(
        address indexed nft,
        address indexed to,
        uint256 indexed tokenId
    );

    /// @notice Emitted when ERC-1155 tokens are transferred out.
    /// @param token  The ERC-1155 contract address.
    /// @param to     The recipient address.
    /// @param id     The token type ID.
    /// @param amount The amount transferred.
    event ERC1155Transferred(
        address indexed token,
        address indexed to,
        uint256 indexed id,
        uint256 amount
    );

    /// @notice Emitted when a low-level call is executed.
    /// @param target The address called.
    /// @param value  The native XOM value sent.
    /// @param data   The calldata forwarded.
    event Executed(
        address indexed target,
        uint256 indexed value,
        bytes data
    );

    /// @notice Emitted after a batch of calls is executed.
    /// @param count The number of calls in the batch.
    event BatchExecuted(uint256 indexed count);

    // ──────────────────────────── Errors ─────────────────────────────

    /// @notice Thrown when an address parameter is the zero address.
    error ZeroAddress();

    /// @notice Thrown when a transfer amount is zero.
    error ZeroAmount();

    /// @notice Thrown when a native XOM transfer fails.
    error NativeTransferFailed();

    /// @notice Thrown when a call in `execute` or `executeBatch` fails.
    /// @param index      The index of the failed call (0 for single).
    /// @param returnData The revert data returned by the failed call.
    error ExecutionFailed(uint256 index, bytes returnData);

    /// @notice Thrown when array lengths do not match in batch calls.
    error ArrayLengthMismatch();

    /// @notice Thrown when `execute` targets `address(this)`.
    error SelfCallNotAllowed();

    /// @notice Thrown when `executeBatch` exceeds the maximum batch size.
    error BatchTooLarge();

    // ─────────────────────────── Constructor ─────────────────────────

    /**
     * @notice Deploy the OmniTreasury and grant initial roles.
     * @dev During Pioneer Phase the `admin` address holds all three
     *      roles. After governance contracts are deployed the admin
     *      should grant roles to them and renounce its own.
     * @param admin The address that receives DEFAULT_ADMIN_ROLE,
     *              GOVERNANCE_ROLE, and GUARDIAN_ROLE.
     */
    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);
    }

    // ───────────────────── Asset Reception ───────────────────────────

    /**
     * @notice Accept incoming native XOM transfers.
     * @dev Emits {NativeReceived}.
     */
    receive() external payable {
        emit NativeReceived(msg.sender, msg.value);
    }

    // ──────────────────── Governance Functions ───────────────────────

    /**
     * @notice Transfer ERC-20 tokens held by this contract.
     * @dev Uses SafeERC20 to handle non-standard return values.
     * @param token  The ERC-20 token to transfer.
     * @param to     The recipient address.
     * @param amount The amount to transfer.
     */
    function transferToken(
        IERC20 token,
        address to,
        uint256 amount
    )
        external
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (address(token) == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        token.safeTransfer(to, amount);

        emit TokenTransferred(address(token), to, amount);
    }

    /**
     * @notice Transfer native XOM held by this contract.
     * @param to     The recipient address (must accept XOM).
     * @param amount The amount of XOM to send (in wei).
     */
    function transferNative(
        address payable to,
        uint256 amount
    )
        external
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert NativeTransferFailed();

        emit NativeTransferred(to, amount);
    }

    /**
     * @notice Approve a spender for an ERC-20 token held by this
     *         contract.
     * @dev Uses SafeERC20.forceApprove to handle tokens that require
     *      resetting allowance to zero first.
     * @param token   The ERC-20 token to approve.
     * @param spender The address being approved.
     * @param amount  The allowance amount.
     */
    function approveToken(
        IERC20 token,
        address spender,
        uint256 amount
    )
        external
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (address(token) == address(0)) revert ZeroAddress();
        if (spender == address(0)) revert ZeroAddress();

        token.forceApprove(spender, amount);

        emit TokenApproved(address(token), spender, amount);
    }

    /**
     * @notice Transfer an ERC-721 NFT held by this contract.
     * @param nft     The ERC-721 contract address.
     * @param to      The recipient address.
     * @param tokenId The token ID to transfer.
     */
    function transferNFT(
        address nft,
        address to,
        uint256 tokenId
    )
        external
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (nft == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();

        IERC721(nft).safeTransferFrom(address(this), to, tokenId);

        emit NFTTransferred(nft, to, tokenId);
    }

    /**
     * @notice Transfer ERC-1155 tokens held by this contract.
     * @param token  The ERC-1155 contract address.
     * @param to     The recipient address.
     * @param id     The token type ID.
     * @param amount The amount to transfer.
     * @param data   Additional data forwarded to the receiver hook.
     */
    function transferERC1155(
        address token,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    )
        external
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC1155(token).safeTransferFrom(
            address(this), to, id, amount, data
        );

        emit ERC1155Transferred(token, to, id, amount);
    }

    /**
     * @notice Execute an arbitrary low-level call. Useful for
     *         interacting with future contracts that do not yet exist.
     * @dev Only `call` is used — `delegatecall` is intentionally
     *      excluded to prevent storage corruption. The target cannot
     *      be `address(this)` to prevent self-call exploits.
     * @param target The contract address to call.
     * @param value  The native XOM to send with the call.
     * @param data   The calldata to forward.
     * @return returnData The bytes returned by the call.
     */
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    )
        external
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused
        nonReentrant
        returns (bytes memory returnData)
    {
        if (target == address(0)) revert ZeroAddress();
        if (target == address(this)) revert SelfCallNotAllowed();

        bool success;
        // solhint-disable-next-line avoid-low-level-calls
        (success, returnData) = target.call{value: value}(data);
        if (!success) revert ExecutionFailed(0, returnData);

        emit Executed(target, value, data);
    }

    /**
     * @notice Execute a batch of arbitrary low-level calls.
     * @dev Reverts on the first failure. All three arrays must have
     *      the same length.
     * @param targets   The addresses to call.
     * @param values    The native XOM amounts for each call.
     * @param calldatas The calldata for each call.
     */
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    )
        external
        onlyRole(GOVERNANCE_ROLE)
        whenNotPaused
        nonReentrant
    {
        uint256 len = targets.length;
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge();
        if (len != values.length || len != calldatas.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i; i < len; ++i) {
            if (targets[i] == address(0)) revert ZeroAddress();
            if (targets[i] == address(this)) {
                revert SelfCallNotAllowed();
            }

            // solhint-disable-next-line avoid-low-level-calls
            (bool success, bytes memory ret) =
                targets[i].call{value: values[i]}(calldatas[i]);
            if (!success) revert ExecutionFailed(i, ret);
        }

        emit BatchExecuted(len);
    }

    // ───────────────────── Guardian Functions ────────────────────────

    /**
     * @notice Pause all governance functions in an emergency.
     * @dev Only callable by GUARDIAN_ROLE.
     */
    function pause()
        external
        onlyRole(GUARDIAN_ROLE)
    {
        _pause();
    }

    /**
     * @notice Resume governance functions after an emergency.
     * @dev Only callable by DEFAULT_ADMIN_ROLE. Separating unpause
     *      from pause prevents a compromised guardian from undoing
     *      its own emergency halt.
     */
    function unpause()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _unpause();
    }

    // ──────────────────────── View Functions ─────────────────────────

    /**
     * @notice Check the treasury's balance of an ERC-20 token.
     * @param token The ERC-20 token to query.
     * @return balance The token balance held by this contract.
     */
    function tokenBalance(
        IERC20 token
    ) external view returns (uint256 balance) {
        balance = token.balanceOf(address(this));
    }

    /**
     * @notice Check the treasury's native XOM balance.
     * @return balance The native XOM balance (in wei).
     */
    function nativeBalance()
        external
        view
        returns (uint256 balance)
    {
        balance = address(this).balance;
    }

    // ──────────────────── Interface Support ──────────────────────────

    /**
     * @notice Declare supported interfaces (ERC-165).
     * @dev Combines AccessControl, ERC721Holder, and ERC1155Holder
     *      interface support.
     * @param interfaceId The 4-byte interface identifier.
     * @return True if the interface is supported.
     */
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(AccessControl, ERC1155Holder)
        returns (bool)
    {
        return
            interfaceId == type(IERC721Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
