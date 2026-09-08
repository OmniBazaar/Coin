// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from
    "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IOmniConduit} from "./interfaces/IOmniConduit.sol";

/**
 * @title  OmniConduit
 * @author OmniBazaar Team
 * @notice Stable approval target for the OmniBazaar NFT exchange. Users
 *         grant `setApprovalForAll` / `approve` to THIS address once, and
 *         the approval keeps working across every future settlement-contract
 *         version.
 *
 * @dev WHY THIS EXISTS.
 *
 *      `NFTMarketplaceEscrow` took approvals directly. Replacing it with
 *      {NFTExchange} therefore strands every approval every seller has ever
 *      granted — they all have to re-approve, per collection, per chain.
 *      That is the cost we are paying once, and this contract is what stops
 *      us paying it again.
 *
 *      Seaport does exactly this with its Conduit (approvals survived
 *      Seaport 1.1 → 1.6 across new addresses), Blur with its Delegate,
 *      Rarible with its TransferProxy. The pattern is settled; we are
 *      copying it, not inventing it.
 *      Reference: `seaport-core/src/conduit/ConduitController.sol`.
 *
 * @dev TRUST MODEL. The conduit performs no accounting and holds no funds
 *      or tokens — every function is a pass-through `transferFrom` executed
 *      against the caller-supplied `from`, and the only authority is the
 *      channel allow-list. An open channel can move any token any user has
 *      approved to this conduit, so opening one is exactly as consequential
 *      as deploying the settlement contract itself. Only ever open a channel
 *      for a contract that has been audited.
 *
 * @dev PIONEER PHASE. The owner is the deployer EOA and stays that way, so
 *      a channel can be opened or closed the moment it is needed. There is
 *      no built-in delay, no propose/apply wait, and no timelock in the
 *      path — those are all banned during Pioneer Phase. The owner is a
 *      plain, swappable address, so the post-Pioneer handover to governance
 *      is a single transfer when the founder authorises that day.
 *
 * @dev Ownership transfer is a two-step propose/accept handshake with **no
 *      waiting period** — the incoming owner may accept in the very next
 *      block. It exists only so the role cannot be handed to an address
 *      that is unable to claim it (a typo, or a contract that cannot call).
 */
contract OmniConduit is IOmniConduit {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────

    /// @notice ERC-165 identifier of the ERC-721 interface.
    bytes4 private constant ERC721_INTERFACE_ID = 0x80ac58cd;

    /// @notice ERC-165 identifier of the draft ERC-721 interface, which
    ///         several valuable 2017-18 collections still answer to
    ///         instead of the final one.
    bytes4 private constant ERC721_DRAFT_INTERFACE_ID = 0x9a20483d;

    /// @notice ERC-165 identifier of the ERC-1155 interface.
    bytes4 private constant ERC1155_INTERFACE_ID = 0xd9b67a26;

    /// @notice Gas allowed to a token's `supportsInterface`, so a hostile
    ///         one cannot burn the caller's gas answering.
    uint256 private constant ERC165_GAS_LIMIT = 30_000;

    // ─── State ────────────────────────────────────────────────────────

    /// @notice Address permitted to open and close channels.
    /// @dev The deployer EOA during Pioneer Phase.
    address public owner;

    /// @notice Address proposed as the next owner; zero when none pending.
    address public pendingOwner;

    /// @notice Contracts permitted to move tokens through this conduit.
    /// @dev `channels[settlementContract] == true` is the whole of the
    ///      authorisation model. Deliberately flat: no per-token, per-user
    ///      or per-amount scoping, because the approvals users grant to a
    ///      conduit are themselves unscoped, so finer-grained channel rules
    ///      would give a false impression of containment.
    mapping(address => bool) public channels;

    // ─── Errors ───────────────────────────────────────────────────────

    /// @notice Caller is not the recorded {owner}.
    error NotOwner();

    /// @notice Caller of `acceptOwnership` is not the recorded {pendingOwner}.
    error NotPendingOwner();

    /// @notice Caller is not an open channel.
    error ChannelClosed();

    /// @notice Zero address supplied where a real address is required.
    error InvalidAddress();

    /// @notice A token named as money is not usable as money — it either
    ///         declares itself an NFT collection, or it does not keep
    ///         ERC-20 allowances at all.
    error NotAPaymentToken();

    /// @notice An address named as an NFT collection did not deliver the
    ///         item — most likely because it is not a collection.
    error NotAnNftCollection();

    // ─── Constructor ──────────────────────────────────────────────────

    /**
     * @notice Record the deploying account as {owner}.
     * @dev No arguments: the Pioneer-Phase rule fixes the owner to the
     *      deployer EOA, so accepting an owner argument would only create
     *      a way to get it wrong.
     */
    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ─── Owner ────────────────────────────────────────────────────────

    /**
     * @notice Open or close a channel.
     * @dev Owner-only. Opening a channel authorises `channel` to move any
     *      token any user has approved to this conduit — see the trust-model
     *      note on the contract.
     * @param channel Contract to authorise or de-authorise.
     * @param open    True to open, false to close.
     */
    function updateChannel(address channel, bool open) external {
        if (msg.sender != owner) revert NotOwner();
        // A channel must be a contract. Opening one is the most
        // consequential call this contract has, and a mistyped address that
        // happens to be an account nobody controls would otherwise become a
        // live, silent lever over every approval held here.
        if (open && channel.code.length == 0) revert InvalidAddress();
        channels[channel] = open;
        emit ChannelUpdated(channel, open);
    }

    /**
     * @notice Nominate the next owner. Pass the zero address to cancel a
     *         pending nomination.
     * @dev Owner-only, and the nominee must call {acceptOwnership} to take
     *      the role. There is no waiting period.
     * @param newOwner Address that may claim ownership, or zero to cancel.
     */
    function proposeOwner(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        pendingOwner = newOwner;
        emit OwnershipProposed(owner, newOwner);
    }

    /**
     * @notice Claim ownership previously nominated via {proposeOwner}.
     * @dev Callable only by the recorded {pendingOwner}. Rotates the role
     *      and clears the nomination in the same call.
     */
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    // ─── Channel transfers ────────────────────────────────────────────

    /**
     * @notice Move one ERC-721 token on behalf of its owner.
     * @dev Plain `transferFrom`, not `safeTransferFrom`: the receiver
     *      callback is a re-entrancy surface the exchange does not need,
     *      and both Seaport and the contract this replaces avoid it for
     *      the same reason. The token owner must have approved this
     *      conduit.
     * @param token   ERC-721 collection.
     * @param from    Current owner.
     * @param to      Recipient.
     * @param tokenId Token to move.
     */
    function transferERC721(
        address token,
        address from,
        address to,
        uint256 tokenId
    ) external {
        if (!channels[msg.sender]) revert ChannelClosed();
        // L-01: Read ownerOf before transfer and verify it changed to `to`.
        // Without the pre-read, a recipient who already owned the token would
        // pass the post-transfer check even if transferFrom silently failed.
        address preOwner = IERC721(token).ownerOf(tokenId);
        IERC721(token).transferFrom(from, to, tokenId);
        _requireDelivered721(token, to, tokenId, preOwner);
    }

    /**
     * @notice Move ERC-1155 units on behalf of their owner.
     * @dev ERC-1155 has no transfer without the receiver callback, so this
     *      one does call back into `to`. Every channel must therefore hold
     *      its own re-entrancy guard across this call; {NFTExchange} does.
     * @param token  ERC-1155 collection.
     * @param from   Current owner.
     * @param to     Recipient.
     * @param id     Token id to move.
     * @param amount Number of units to move.
     */
    function transferERC1155(
        address token,
        address from,
        address to,
        uint256 id,
        uint256 amount
    ) external {
        if (!channels[msg.sender]) revert ChannelClosed();
        // M-01: Read pre-transfer balance and verify exact delta post-transfer.
        // The old check (held >= amount) passed silently when the recipient
        // already held tokens, masking a failed transfer.
        uint256 preBalance = IERC1155(token).balanceOf(to, id);
        IERC1155(token).safeTransferFrom(from, to, id, amount, "");
        _requireDelivered1155(token, to, id, amount, preBalance);
    }

    /**
     * @notice Move ERC-20 tokens on behalf of their owner.
     *
     * @dev 🛑 AN NFT COLLECTION IS NOT MONEY, AND THE TWO ARE HARD TO TELL
     *      APART. `transferFrom(address,address,uint256)` has the identical
     *      selector `0x23b872dd` on ERC-20 and on ERC-721, and
     *      `SafeERC20.safeTransferFrom` accepts a contract that returns
     *      nothing — which ERC-721's `transferFrom` does. So without the
     *      check below, naming a collection as an order's payment token
     *      turns this function into `collection.transferFrom(payer,
     *      recipient, amount)`, where `amount` is read as a token id.
     *
     *      The victim would be someone who has approved this conduit for a
     *      collection of their own, which is every seller on the exchange.
     *      Choosing a price under 100 makes the 1% marketplace fee round to
     *      zero, so the whole payment collapses to a single leg and one of
     *      the buyer's own NFTs walks out.
     *
     *      {_rejectNftCollection} closes it. A collection a buyer would
     *      realistically have approved is a real, deployed ERC-721, and real
     *      ERC-721s answer ERC-165 honestly. A contract that lies about
     *      ERC-165 to get past this is one nobody has approved.
     *
     *      The check lives here rather than in the settlement contract on
     *      purpose: the conduit is what holds the approvals, so every future
     *      channel inherits the protection without having to remember it.
     *
     * @param token  ERC-20 token.
     * @param from   Payer.
     * @param to     Recipient.
     * @param amount Amount in the token's smallest units.
     */
    function transferERC20(
        address token,
        address from,
        address to,
        uint256 amount
    ) external {
        if (!channels[msg.sender]) revert ChannelClosed();
        _requirePaymentToken(token, from, amount);
        IERC20(token).safeTransferFrom(from, to, amount);
    }

    /**
     * @notice Refuse to treat anything but real money as money.
     *
     * @dev Two gates, because one is not enough.
     *
     *      The FIRST is positive and is the one that actually closes the
     *      attack: every ERC-20 keeps allowances, and `allowance` is
     *      mandatory in the standard, so a payer who is about to have
     *      `amount` pulled from them must already show an allowance of at
     *      least that much. An NFT collection has no
     *      `allowance(address,address)` — ERC-721 spells approval
     *      `getApproved(uint256)` — so the call finds no such function and
     *      reverts, and the collection is turned away. This holds for
     *      collections that predate ERC-165 and for collections that answer
     *      ERC-165 expensively, neither of which the second gate catches.
     *
     *      The SECOND is the ERC-165 declaration check, kept as an
     *      independent gate and widened to the draft ERC-721 identifier and
     *      to ERC-1155. It fails open — a contract with no ERC-165 is
     *      accepted — which is why it cannot be the only gate, and why the
     *      allowance gate comes first.
     *
     * @param token  Address named as an order's payment token.
     * @param payer  Account the money will be pulled from.
     * @param amount Amount about to be pulled.
     */
    function _requirePaymentToken(
        address token,
        address payer,
        uint256 amount
    ) private view {
        try IERC20(token).allowance(payer, address(this)) returns (
            uint256 approved
        ) {
            if (approved < amount) revert NotAPaymentToken();
        } catch {
            revert NotAPaymentToken();
        }

        if (
            _declaresInterface(token, ERC721_INTERFACE_ID) ||
            _declaresInterface(token, ERC721_DRAFT_INTERFACE_ID) ||
            _declaresInterface(token, ERC1155_INTERFACE_ID)
        ) {
            revert NotAPaymentToken();
        }
    }

    /**
     * @notice Refuse to call anything but a real collection a collection.
     *
     * @dev The mirror of {_requirePaymentToken}, and just as necessary:
     *      `transferFrom(address,address,uint256)` is ambiguous in BOTH
     *      directions. An ERC-20 named as an order's collection turns the
     *      delivery leg into `token.transferFrom(seller, buyer, tokenId)`
     *      with the token id read as an amount, which drains whatever the
     *      seller has approved to this conduit. Guarding only the money
     *      side left that wide open.
     *
     *      Checking afterwards rather than before is deliberate: asking who
     *      owns the item now both proves the address is a collection (an
     *      ERC-20 has no `ownerOf`, so the call reverts) and proves the item
     *      actually arrived, which also catches a collection whose transfer
     *      quietly does nothing.
     *
     * @param token   Collection that was asked to move the item.
     * @param to      Who should now hold it.
     * @param tokenId Item that should have moved.
     */
    function _requireDelivered721(
        address token,
        address to,
        uint256 tokenId,
        address preOwner
    ) private view {
        try IERC721(token).ownerOf(tokenId) returns (address holder) {
            if (holder != to) revert NotAnNftCollection();
            if (holder == preOwner) revert NotAnNftCollection();
        } catch {
            revert NotAnNftCollection();
        }
    }

    /**
     * @notice The ERC-1155 half of {_requireDelivered721}.
     * @dev `balanceOf(address,uint256)` is a different function from an
     *      ERC-20's `balanceOf(address)` — different selector — so an
     *      ERC-20 named as an ERC-1155 collection reverts here.
     * @param token  Collection that was asked to move the units.
     * @param to     Who should now hold them.
     * @param id     Item that should have moved.
     * @param amount How many units moved.
     */
    function _requireDelivered1155(
        address token,
        address to,
        uint256 id,
        uint256 amount,
        uint256 preBalance
    ) private view {
        try IERC1155(token).balanceOf(to, id) returns (uint256 held) {
            if (held != preBalance + amount) revert NotAnNftCollection();
        } catch {
            revert NotAnNftCollection();
        }
    }

    /**
     * @notice Whether a contract affirmatively claims an interface.
     * @dev Gas-bounded so a hostile contract cannot spend the caller's gas
     *      answering, and tolerant of contracts with no ERC-165 at all.
     * @param token       Contract to ask.
     * @param interfaceId Interface to ask about.
     * @return declares True only if it answered yes.
     */
    function _declaresInterface(address token, bytes4 interfaceId)
        private
        view
        returns (bool declares)
    {
        try
            IERC165(token).supportsInterface{gas: ERC165_GAS_LIMIT}(
                interfaceId
            )
        returns (bool answer) {
            return answer;
        } catch {
            return false;
        }
    }
}
