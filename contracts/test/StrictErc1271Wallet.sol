// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title  StrictErc1271Wallet
 * @author OmniBazaar Team
 * @notice A smart-contract wallet that approves exactly one digest and
 *         ignores the signature bytes entirely, so a test can prove WHICH
 *         digest `NFTExchange._verifySignature` fed it.
 * @dev Test-only. Four concatenated 65-byte owner signatures come to 260
 *      bytes, which is exactly the bulk-signature shape `68 + 32 * 6` — so
 *      deciding plain-versus-bulk by length alone used to hand every
 *      4-of-N Safe a Merkle digest it had never approved, and such a
 *      wallet could not sell anything at all.
 */
contract StrictErc1271Wallet {
    /// @notice The one digest this wallet considers signed.
    bytes32 public approvedHash;

    /// @notice A pass-through call failed.
    error CallFailed();

    /// @notice Accept the chain's own currency, so sale proceeds land.
    receive() external payable {}

    /**
     * @notice Set the approved digest. Anyone may call; this is a double.
     * @param hash Digest to approve.
     */
    function approve(bytes32 hash) external {
        approvedHash = hash;
    }

    /**
     * @notice Approve an operator on a collection, so the wallet can list.
     * @param collection ERC-721 or ERC-1155 collection.
     * @param operator   Operator to authorise.
     */
    function setApprovalForAll(address collection, address operator) external {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, ) = collection.call(
            abi.encodeWithSignature(
                "setApprovalForAll(address,bool)",
                operator,
                true
            )
        );
        if (!ok) revert CallFailed();
    }

    /**
     * @notice ERC-1271 check. Ignores the signature bytes entirely, so the
     *         only thing that decides the answer is which digest it was
     *         handed.
     * @param hash Digest the caller wants validated.
     * @return magic The ERC-1271 magic value, or zero.
     */
    function isValidSignature(bytes32 hash, bytes calldata)
        external
        view
        returns (bytes4 magic)
    {
        return hash == approvedHash ? bytes4(0x1626ba7e) : bytes4(0);
    }
}
