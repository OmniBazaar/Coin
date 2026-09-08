// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITokenReceiver} from "../coti-helium/token/PrivateERC20/ITokenReceiver.sol";

/**
 * @title MockPrivateXom
 * @author OmniCoin Development Team
 * @notice Hardhat-only stand-in for the canonical encrypted pXOM
 *         (`PrivateOmniCoin` / COTI `PrivateERC20`). The real token's
 *         mint/burn/transfer paths run through COTI's MPC precompile, which
 *         does not exist under Hardhat — so this mock reproduces the
 *         PUBLIC-amount surface `OmniPrivacyShield` depends on
 *         (`mint`, `burn`, `transferFrom`, `transferAndCall`) with plain
 *         (unencrypted) balances. It lets us unit-test the shield's vault
 *         accounting + access control off-chain; the real MPC mint/burn is
 *         verified separately on COTI testnet (per `Coin/CLAUDE.md`).
 * @dev    NOT for production. Mocks only the methods the shield calls.
 *
 *         **Guard-accurate.** `transferAndCall`, `burn`, and `transferFrom`
 *         carry `nonReentrant`, exactly mirroring `PrivateERC20`. This is
 *         deliberate and load-bearing: the original mock omitted these guards,
 *         which is why the unit tests passed while the *real* unshield reverted
 *         on COTI — `transferAndCall` (nonReentrant) called a callback that
 *         called `burn` (nonReentrant on the same token) → re-entry revert.
 *         With the guards present, the mock reproduces that revert (see
 *         {ReentrantBurnReceiver}) and proves the two-step `unshield` fix.
 */
contract MockPrivateXom is ERC20, ReentrancyGuard {
    /// @notice Deploy the mock with the pXOM name/symbol for parity.
    constructor() ERC20("Private OmniCoin (mock)", "pXOM") {}

    /**
     * @notice Mint public-amount tokens (mirrors `PrivateERC20.mint(address,uint256)`).
     * @param to     Recipient.
     * @param amount Amount minted.
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Burn public-amount tokens from the caller (mirrors
     *         `PrivateERC20.burn(uint256)`, including its `nonReentrant` guard).
     * @param amount Amount burned from `msg.sender`.
     */
    function burn(uint256 amount) external nonReentrant {
        _burn(msg.sender, amount);
    }

    /**
     * @notice Public-amount `transferFrom` (mirrors
     *         `PrivateERC20.transferFrom(address,address,uint256)`'s
     *         `nonReentrant` guard). Used by {OmniPrivacyShield.unshield}.
     * @param from   Owner whose tokens are moved (must have approved caller).
     * @param to     Recipient.
     * @param amount Public amount to transfer.
     * @return success True on success.
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override nonReentrant returns (bool success) {
        return super.transferFrom(from, to, amount);
    }

    /**
     * @notice Transfer then invoke the recipient's `onTokenReceived`
     *         (mirrors `PrivateERC20.transferAndCall` public-amount path,
     *         including its `nonReentrant` guard).
     * @param to     Recipient contract (must implement {ITokenReceiver}).
     * @param amount Public amount to transfer.
     * @param data   Opaque callback data forwarded to the receiver.
     */
    function transferAndCall(address to, uint256 amount, bytes calldata data) external nonReentrant {
        _transfer(msg.sender, to, amount);
        require(
            ITokenReceiver(to).onTokenReceived(msg.sender, amount, data),
            "MockPrivateXom: callback failed"
        );
    }
}

/**
 * @title ReentrantBurnReceiver
 * @author OmniCoin Development Team
 * @notice Test-only receiver that reproduces the original (broken) unshield
 *         design: it calls `pXOM.burn()` from inside `onTokenReceived`. Driven
 *         via `MockPrivateXom.transferAndCall(thisReceiver, amount)`, it must
 *         revert with a re-entrancy error because the burn re-enters the
 *         `transferAndCall` guard — the exact defect that made the old
 *         `OmniPrivacyShield.onTokenReceived` unshield path impossible.
 * @dev    NOT for production. Exists solely to assert the bug in a guard-
 *         accurate Hardhat test.
 */
contract ReentrantBurnReceiver is ITokenReceiver {
    /// @notice The mock pXOM whose `burn` is (re-entrantly) called.
    MockPrivateXom public immutable pxom;

    /**
     * @notice Bind the receiver to the mock pXOM.
     * @param pxom_ The {MockPrivateXom} instance.
     */
    constructor(MockPrivateXom pxom_) {
        pxom = pxom_;
    }

    /**
     * @notice Callback invoked by `transferAndCall`; re-enters via `burn`.
     * @param amount Amount transferred in (burned re-entrantly).
     * @return Always true if it did not revert (it will revert on re-entry).
     */
    function onTokenReceived(
        address,
        uint256 amount,
        bytes calldata
    ) external override returns (bool) {
        pxom.burn(amount);
        return true;
    }
}
