// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ITokenReceiver} from "../coti-helium/token/PrivateERC20/ITokenReceiver.sol";

/**
 * @title IPrivateMintBurn
 * @author OmniCoin Development Team
 * @notice Minimal pXOM surface the shield drives (canonical PrivateERC20 public-amount paths).
 */
interface IPrivateMintBurn {
    /// @notice Mint `amount` (public) pXOM to `to`. Requires MINTER_ROLE.
    /// @param to     Recipient of the freshly minted pXOM.
    /// @param amount Public amount to mint (18-dec).
    function mint(address to, uint256 amount) external;

    /// @notice Burn `amount` (public) pXOM from the caller's encrypted balance.
    /// @dev {OmniPrivacyShield.burnPending} calls this on the shield's OWN
    ///      accumulated balance, in a tx separate from receipt.
    /// @param amount Public amount to burn (18-dec).
    function burn(uint256 amount) external;
}

/**
 * @title OmniPrivacyShield
 * @author OmniCoin Development Team
 * @notice COTI-side shield: converts public, Hyperlane-bridged wrapped XOM
 *         (`wXOM`, a standard `HypERC20`) into encrypted `pXOM`
 *         (the canonical COTI `PrivateERC20`), and back. This is the ONLY
 *         bespoke contract retained under the 2026-05-30 bridge pivot
 *         (`memory/decision_privacy_bridge_hyperlane_2026-05-30.md`): the
 *         cross-chain crossing itself is a Hyperlane Warp Route + a
 *         MultisigISM of OmniBazaar's own validators — proven, COTI-endorsed
 *         interop infra — so this contract does NO cross-chain attestation,
 *         signature verification, or messaging. It is a pure 1:1 vault that
 *         straddles the public↔private boundary on COTI 2632500.
 *
 * @dev    **Why a wrapper at all.** A Hyperlane Warp Route can only land a
 *         standard (public) ERC20 on COTI; it has no notion of COTI's
 *         encrypted balances. COTI's own norm (the Privacy Portal) is
 *         "bridge a public token, then shield it separately." The Privacy
 *         Portal is a curated whitelist that will not self-add XOM, so we
 *         provide the canonical shield step ourselves — using COTI's
 *         `PrivateERC20` standard, not bespoke crypto.
 *
 *         **Direction asymmetry (deliberate, canonical).**
 *           - SHIELD (public → private): {shield} pulls `amount` wXOM from
 *             the caller (1:1 collateral, held by this contract) and mints
 *             `amount` pXOM to the caller via `pXOM.mint(to, uint256)`. The
 *             input amount is already public (an ERC20 transfer); the
 *             privacy is acquired the instant it lands in the encrypted
 *             pXOM balance.
 *           - UNSHIELD (private → public): the user PUSHES pXOM to this
 *             shield via `pXOM.transferAndCall(thisShield, amount, "")`, which
 *             transfers the pXOM and then invokes {onTokenReceived}; the shield
 *             releases `amount` wXOM 1:1. There is NO `approve` and NO contract
 *             pull. The user reveals the amount voluntarily by passing it
 *             publicly; no MPC off-board / decryption is performed here.
 *
 *             **Why a push (not a pull), and why the burn is deferred (verified
 *             on COTI mainnet 2026-06-17).** Two pull-based forms fail on COTI:
 *             (1) `pXOM.transferFrom` with a CONTRACT (the shield) as the
 *             allowance spender reverts at the MPC precompile (unshield tx
 *             `0x2a8bf038`), even though `transferFrom` with an EOA spender
 *             works; (2) burning the received pXOM in the same tx also reverts
 *             (a contract cannot spend a balance it received in the same tx,
 *             plus re-entry into `transferAndCall`'s `nonReentrant` guard).
 *             Isolation proved the primitives that DO work: a user-initiated
 *             push transfer to a contract, and a separate-tx self-burn. So the
 *             shield receives via the {onTokenReceived} push callback (no pXOM
 *             call inside it) and burns the accumulated pXOM later in
 *             {burnPending}. Public-amount pXOM spend itself is fully functional
 *             (`publicAmountsEnabled == true`); no encrypted `itUint256` path
 *             is required.
 *
 *         **Invariant.** `wXOM.balanceOf(this) >= collateralised` at all times
 *         (`==` absent unsolicited wXOM donations — see {collateralised}).
 *         `collateralised` is the wXOM backing outstanding, circulating pXOM
 *         minted by this shield; releases are bounded by it (NOT by balance), so
 *         a donation can never be unshielded against. The shield may
 *         additionally hold up to {pendingBurn} pXOM awaiting {burnPending};
 *         that pXOM is non-circulating and backs nothing. Both tokens are
 *         18-dec, so the collateral mapping is exactly 1:1 with no scaling.
 *
 *         **Collateral is non-custodial (no break-glass sweep — deliberate).**
 *         There is intentionally no owner function to withdraw collateral or
 *         surplus: the owner can never touch user wXOM (preserves the
 *         non-custodial invariant). The trade-off (audit F-1): if the immutable
 *         {pxom} token were ever retired/paused, users could no longer push pXOM
 *         to unshield and collateral would strand with no on-chain rescue. The
 *         mitigation is OPERATIONAL, not a sweep: never revoke this shield's
 *         pXOM `MINTER_ROLE` or retire/pause pXOM before migrating to a
 *         replacement shield. Existing holders can always unshield as long as
 *         pXOM itself is live (unshield needs no role).
 *
 *         **Trust + roles.** This contract must hold `MINTER_ROLE` on pXOM
 *         (granted by the pXOM `DEFAULT_ADMIN_ROLE` holder, replacing the
 *         retired bespoke bridge). It is `Ownable2Step` so the owner can
 *         pause and (post-Pioneer) be rotated; per the Pioneer-phase rule the
 *         owner is the deployer EOA at launch, with no built-in delays.
 *
 *         **Chain guard.** Constructor reverts unless on COTI 2632500 (or
 *         the COTI testnet) — the pXOM MPC precompile does not exist
 *         elsewhere, mirroring `PrivateOmniCoin`'s guard.
 *
 *         **MPC testability.** The pXOM mint/burn paths exercise COTI's MPC
 *         precompile, which exists only on COTI networks. Per
 *         `Coin/CLAUDE.md`, the public ERC20 vault accounting + access
 *         control are unit-tested in Hardhat against a mock pXOM; the live
 *         MPC mint/burn is verified on COTI testnet.
 */
contract OmniPrivacyShield is Ownable2Step, ReentrancyGuard, Pausable, ITokenReceiver {
    using SafeERC20 for IERC20;

    /// @notice COTI V2 mainnet chain id.
    uint256 public constant COTI_CHAIN_ID = 2632500;

    /// @notice COTI V2 testnet chain id (same MPC semantics; used for integration tests).
    uint256 public constant COTI_TESTNET_CHAIN_ID = 7082400;

    /// @notice The public, Hyperlane-bridged wrapped XOM held 1:1 as collateral.
    IERC20 public immutable wrappedXom;

    /// @notice The canonical encrypted pXOM (`PrivateOmniCoin`) this contract mints/burns.
    IPrivateMintBurn public immutable pxom;

    /// @notice Total wXOM currently collateralising outstanding pXOM minted by this shield.
    /// @dev Increases on {shield}, decreases on unshield. Equals `wrappedXom.balanceOf(this)`
    ///      in the absence of unsolicited transfers; tracked explicitly so a donation to the
    ///      contract cannot be unshielded against.
    uint256 public collateralised;

    /// @notice pXOM this shield has taken custody of via {unshield} but not yet burned.
    /// @dev On COTI a contract cannot burn a pXOM balance it received in the SAME tx (the
    ///      garbled receive-credit is not spendable until the tx settles), so {unshield}
    ///      accumulates the pulled pXOM here and {burnPending} burns it in a later, separate
    ///      tx. This balance is non-circulating and does NOT back any collateral — burning it
    ///      is hygiene, not a correctness requirement (see {burnPending}).
    uint256 public pendingBurn;

    /// @notice Emitted when a caller shields public wXOM into encrypted pXOM.
    /// @param account The shielding account (receives pXOM).
    /// @param amount  Amount shielded (18-dec, 1:1).
    event Shielded(address indexed account, uint256 amount);

    /// @notice Emitted when a caller unshields encrypted pXOM back into public wXOM.
    /// @param account The unshielding account (receives wXOM).
    /// @param amount  Amount unshielded (18-dec, 1:1).
    event Unshielded(address indexed account, uint256 amount);

    /// @notice Emitted when the owner burns accumulated pXOM via {burnPending}.
    /// @param amount    Amount of accumulated pXOM burned (18-dec).
    /// @param remaining Remaining {pendingBurn} after this burn.
    event PendingBurned(uint256 amount, uint256 remaining);

    /// @notice Thrown when deployed on a chain without the COTI MPC precompile.
    error WrongChain(uint256 actual, uint256 expected);
    /// @notice Thrown when a constructor address argument is the zero address.
    error ZeroAddress();
    /// @notice Thrown when a shield/unshield amount is zero.
    error ZeroAmount();
    /// @notice Thrown when an unshield would exceed the wXOM collateral this shield holds.
    error InsufficientCollateral(uint256 requested, uint256 available);
    /// @notice Thrown when {burnPending} is asked to burn more than the accumulated {pendingBurn}.
    error InsufficientPending(uint256 requested, uint256 available);
    /// @notice Thrown when {onTokenReceived} is called by anyone other than the pXOM token.
    error OnlyPxom(address caller);

    /**
     * @notice Deploy the shield, binding it to the wXOM and pXOM tokens.
     * @dev Reverts off COTI. The deployer becomes the `Ownable2Step` owner.
     *      The pXOM `MINTER_ROLE` must be granted to this contract separately
     *      by the pXOM admin (the deployer) after deployment.
     * @param wrappedXom_ Hyperlane-bridged public wrapped XOM (HypERC20) on COTI.
     * @param pxom_       Canonical encrypted pXOM (`PrivateOmniCoin`) on COTI.
     */
    constructor(address wrappedXom_, address pxom_) Ownable(msg.sender) {
        if (block.chainid != COTI_CHAIN_ID && block.chainid != COTI_TESTNET_CHAIN_ID) {
            revert WrongChain(block.chainid, COTI_CHAIN_ID);
        }
        if (wrappedXom_ == address(0) || pxom_ == address(0)) revert ZeroAddress();
        wrappedXom = IERC20(wrappedXom_);
        pxom = IPrivateMintBurn(pxom_);
    }

    /**
     * @notice Shield public wXOM into encrypted pXOM (1:1).
     * @dev Pulls `amount` wXOM from the caller (requires prior ERC20
     *      approval), books it as collateral, and mints `amount` pXOM to the
     *      caller. The caller's pXOM balance is encrypted on-chain from this
     *      point; only the caller can decrypt it.
     * @param amount Amount of wXOM to shield (18-dec). Must be non-zero.
     */
    function shield(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        uint256 balanceBefore = wrappedXom.balanceOf(address(this));
        wrappedXom.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = wrappedXom.balanceOf(address(this)) - balanceBefore;
        collateralised += received;
        pxom.mint(msg.sender, received);
        emit Shielded(msg.sender, received);
    }

    /**
     * @notice UNSHIELD entry point: receive pXOM pushed via
     *         `pXOM.transferAndCall(thisShield, amount, "")` and release
     *         `amount` wXOM 1:1 to the user.
     * @dev Called by the pXOM token at the end of {PrivateERC20-transferAndCall}:
     *      the pXOM has ALREADY been transferred from the user to this contract
     *      when this runs, and `from` is the user (pXOM's `_msgSender`). Unshield
     *      is a USER-INITIATED PUSH, not a contract pull: on COTI,
     *      `pXOM.transferFrom` with a CONTRACT as the allowance spender reverts
     *      at the MPC precompile (verified on mainnet 2026-06-17, unshield tx
     *      `0x2a8bf038`), while a user-initiated push transfer to a contract
     *      works. We deliberately do NOT call back into pXOM here (no burn):
     *      that would (a) re-enter `transferAndCall`'s held `nonReentrant` guard
     *      — the original `onTokenReceived`→burn defect — and (b) hit COTI's
     *      same-tx receive+burn revert. The received pXOM is accumulated in
     *      {pendingBurn} and burned later by {burnPending} in a separate tx.
     *      Safe: collateral is decremented here so the released wXOM is backed
     *      1:1, and the held pXOM is non-circulating regardless of whether it is
     *      ever burned. Only the trusted pXOM token may call this.
     * @param from   The unshielding user (receives wXOM); pXOM's `_msgSender`.
     * @param amount Public amount of pXOM received (== wXOM released), 18-dec.
     * @return ok Always true on success; reverts otherwise (per {ITokenReceiver}).
     */
    function onTokenReceived(
        address from,
        uint256 amount,
        bytes calldata /* data */
    ) external override nonReentrant whenNotPaused returns (bool ok) {
        if (from == address(0)) revert ZeroAddress();
        if (msg.sender != address(pxom)) revert OnlyPxom(msg.sender);
        if (amount == 0) revert ZeroAmount();
        if (amount > collateralised) revert InsufficientCollateral(amount, collateralised);
        collateralised -= amount;
        pendingBurn += amount;
        wrappedXom.safeTransfer(from, amount);
        emit Unshielded(from, amount);
        return true;
    }

    /**
     * @notice Burn pXOM the shield has accumulated from {unshield}, in a tx
     *         separate from the receipt (required by COTI MPC — see {unshield}).
     * @dev Owner-only hygiene that reduces the shield's locked, non-circulating
     *      pXOM. It is NOT a correctness requirement: if a contract cannot
     *      self-burn pXOM at all on the deployed token, this call reverts and
     *      the pXOM simply stays locked here — collateral accounting and user
     *      funds are unaffected. Burns from this contract's own balance, so no
     *      same-tx receive+burn occurs. Reverts if `amount` exceeds
     *      {pendingBurn}.
     * @param amount Public amount of accumulated pXOM to burn (18-dec). Non-zero.
     */
    function burnPending(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > pendingBurn) revert InsufficientPending(amount, pendingBurn);
        pendingBurn -= amount;
        pxom.burn(amount);
        emit PendingBurned(amount, pendingBurn);
    }

    /// @notice Pause shielding + unshielding (owner only). Emergency stop.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume shielding + unshielding (owner only).
    function unpause() external onlyOwner {
        _unpause();
    }
}
