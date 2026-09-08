// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/**
 * @title MockPlatform
 * @author OmniBazaar Development Team
 * @notice Mock prediction market platform for testing OmniPredictionRouter.
 * @dev Simulates a platform that accepts collateral and optionally mints
 *      ERC-20 or ERC-1155 outcome tokens back to the caller or to the router.
 *      Supports configurable failure mode for testing revert paths.
 */
contract MockPlatform is ERC1155 {
    /// @notice If true, the execute() call will revert.
    bool public shouldFail;

    /// @notice Optional ERC-20 outcome token to mint to a recipient on execute.
    address public outcomeToken;

    /// @notice Amount of ERC-20 outcome tokens to mint on execute.
    uint256 public outcomeAmount;

    /// @notice Recipient of ERC-20 outcome tokens (typically the router).
    address public outcomeRecipient;

    /// @notice ERC-1155 token ID to mint on execute.
    uint256 public erc1155TokenId;

    /// @notice Amount of ERC-1155 tokens to mint on execute.
    uint256 public erc1155Amount;

    /// @notice Recipient of ERC-1155 tokens on execute.
    address public erc1155Recipient;

    /// @notice Deploy mock platform with empty ERC-1155 URI.
    constructor() ERC1155("") {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Configure the mock to fail or succeed on execute().
     * @param _shouldFail Whether execute() should revert.
     */
    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    /**
     * @notice Configure ERC-20 outcome token minting on execute().
     * @param _outcomeToken ERC-20 mock token with public mint.
     * @param _outcomeAmount Amount to mint.
     * @param _outcomeRecipient Recipient of minted tokens.
     */
    function setOutcomeERC20(
        address _outcomeToken,
        uint256 _outcomeAmount,
        address _outcomeRecipient
    ) external {
        outcomeToken = _outcomeToken;
        outcomeAmount = _outcomeAmount;
        outcomeRecipient = _outcomeRecipient;
    }

    /**
     * @notice Configure ERC-1155 outcome token minting on execute().
     * @param _tokenId ERC-1155 token ID.
     * @param _amount Amount to mint.
     * @param _recipient Recipient of minted tokens.
     */
    function setOutcomeERC1155(
        uint256 _tokenId,
        uint256 _amount,
        address _recipient
    ) external {
        erc1155TokenId = _tokenId;
        erc1155Amount = _amount;
        erc1155Recipient = _recipient;
    }

    /**
     * @notice Mock platform execution entry point.
     * @dev Accepts collateral (already approved by the router) and optionally
     *      mints outcome tokens. Reverts if shouldFail is true.
     */
    function execute() external {
        require(!shouldFail, "MockPlatform: execution failed");

        // Mint ERC-20 outcome tokens if configured
        if (outcomeToken != address(0) && outcomeAmount > 0) {
            // Call the MockERC20's public mint function
            // solhint-disable-next-line avoid-low-level-calls
            (bool success,) = outcomeToken.call(
                abi.encodeWithSignature(
                    "mint(address,uint256)",
                    outcomeRecipient,
                    outcomeAmount
                )
            );
            require(success, "MockPlatform: ERC20 mint failed");
        }

        // Mint ERC-1155 outcome tokens if configured
        if (erc1155Recipient != address(0) && erc1155Amount > 0) {
            _mint(erc1155Recipient, erc1155TokenId, erc1155Amount, "");
        }
    }

    /**
     * @notice Mint ERC-1155 tokens to any address (testing only).
     * @param to Recipient.
     * @param id Token type ID.
     * @param amount Amount to mint.
     */
    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}
