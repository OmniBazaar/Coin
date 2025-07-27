// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OmniCoinPrivacy is Ownable, ReentrancyGuard {
    // Custom errors
    error ZeroCommitment();
    error AccountExists();
    error AccountNotFound();
    error InsufficientBalance();
    error InvalidAmount();
    error BelowMinDeposit();
    error ExceedsMaxWithdrawal();
    error TransferFailed();
    error InvalidNullifier();
    error NullifierAlreadySpent();
    error InvalidProof();
    error ZeroAmount();
    error InactiveAccount();
    
    struct PrivacyAccount {
        bytes32 commitment;
        uint256 balance;
        uint256 nonce;
        bool isActive;
    }

    IERC20 public token;
    uint256 public minDeposit;
    uint256 public maxWithdrawal;
    uint256 public privacyFee;

    mapping(bytes32 => PrivacyAccount) public accounts;
    mapping(bytes32 => bool) public spentNullifiers;

    event AccountCreated(bytes32 indexed commitment);
    event AccountClosed(bytes32 indexed commitment);
    event Deposit(bytes32 indexed commitment, uint256 amount);
    event Withdrawal(bytes32 indexed commitment, uint256 amount);
    event Transfer(
        bytes32 indexed fromCommitment,
        bytes32 indexed toCommitment,
        uint256 amount
    );
    event MinDepositUpdated(uint256 oldAmount, uint256 newAmount);
    event MaxWithdrawalUpdated(uint256 oldAmount, uint256 newAmount);
    event PrivacyFeeUpdated(uint256 oldFee, uint256 newFee);

    constructor(address _token, address initialOwner) Ownable(initialOwner) {
        token = IERC20(_token);
        minDeposit = 100 * 10 ** 18; // 100 tokens
        maxWithdrawal = 1000 * 10 ** 18; // 1000 tokens
        privacyFee = 1 * 10 ** 18; // 1 token
    }

    function createAccount(bytes32 commitment) external nonReentrant {
        if (commitment == bytes32(0)) revert ZeroCommitment();
        if (accounts[commitment].isActive) revert AccountExists();

        accounts[commitment] = PrivacyAccount({
            commitment: commitment,
            balance: 0,
            nonce: 0,
            isActive: true
        });

        emit AccountCreated(commitment);
    }

    function closeAccount(bytes32 commitment) external nonReentrant {
        PrivacyAccount storage account = accounts[commitment];
        if (!account.isActive) revert InactiveAccount();
        if (account.balance != 0) revert InsufficientBalance();

        account.isActive = false;

        emit AccountClosed(commitment);
    }

    function deposit(bytes32 commitment, uint256 amount) external nonReentrant {
        if (amount < minDeposit) revert BelowMinDeposit();
        if (amount > maxWithdrawal) revert ExceedsMaxWithdrawal();

        PrivacyAccount storage account = accounts[commitment];
        if (!account.isActive) revert InactiveAccount();

        if (!token.transferFrom(msg.sender, address(this), amount))
            revert TransferFailed();

        account.balance += amount;

        emit Deposit(commitment, amount);
    }

    function withdraw(
        bytes32 commitment,
        bytes32 nullifier,
        uint256 amount,
        bytes memory proof
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > maxWithdrawal) revert ExceedsMaxWithdrawal();
        if (spentNullifiers[nullifier]) revert NullifierAlreadySpent();

        PrivacyAccount storage account = accounts[commitment];
        if (!account.isActive) revert InactiveAccount();
        if (account.balance < amount) revert InsufficientBalance();

        // Verify proof (to be implemented)
        if (!verifyWithdrawal(commitment, nullifier, amount, proof))
            revert InvalidProof();

        spentNullifiers[nullifier] = true;
        account.balance -= amount;
        account.nonce++;

        if (!token.transfer(msg.sender, amount - privacyFee))
            revert TransferFailed();

        emit Withdrawal(commitment, amount);
    }

    function transfer(
        bytes32 fromCommitment,
        bytes32 toCommitment,
        bytes32 nullifier,
        uint256 amount,
        bytes memory proof
    ) external nonReentrant {
        require(amount > 0, "OmniCoinPrivacy: zero amount");
        require(
            !spentNullifiers[nullifier],
            "OmniCoinPrivacy: nullifier spent"
        );

        PrivacyAccount storage fromAccount = accounts[fromCommitment];
        PrivacyAccount storage toAccount = accounts[toCommitment];
        if (!fromAccount.isActive) revert InactiveAccount();
        if (!toAccount.isActive) revert InactiveAccount();
        if (fromAccount.balance < amount) revert InsufficientBalance();

        // Verify proof (to be implemented)
        if (!verifyTransfer(
                fromCommitment,
                toCommitment,
                nullifier,
                amount,
                proof
            )) revert InvalidProof();

        spentNullifiers[nullifier] = true;
        fromAccount.balance -= amount;
        fromAccount.nonce++;
        toAccount.balance += amount;

        emit Transfer(fromCommitment, toCommitment, amount);
    }

    function setMinDeposit(uint256 _amount) external onlyOwner {
        emit MinDepositUpdated(minDeposit, _amount);
        minDeposit = _amount;
    }

    function setMaxWithdrawal(uint256 _amount) external onlyOwner {
        emit MaxWithdrawalUpdated(maxWithdrawal, _amount);
        maxWithdrawal = _amount;
    }

    function setPrivacyFee(uint256 _fee) external onlyOwner {
        emit PrivacyFeeUpdated(privacyFee, _fee);
        privacyFee = _fee;
    }

    function verifyWithdrawal(
        bytes32 commitment,
        bytes32 nullifier,
        uint256 amount,
        bytes memory circuitProof
    ) internal view returns (bool) {
        // TODO: Implement garbled circuit verification
        return true;
    }

    function verifyTransfer(
        bytes32 fromCommitment,
        bytes32 toCommitment,
        bytes32 nullifier,
        uint256 amount,
        bytes memory circuitProof
    ) internal view returns (bool) {
        // TODO: Implement garbled circuit verification
        return true;
    }

    function getAccount(
        bytes32 commitment
    )
        external
        view
        returns (
            bytes32 accountCommitment,
            uint256 balance,
            uint256 nonce,
            bool isActive
        )
    {
        PrivacyAccount storage account = accounts[commitment];
        return (
            account.commitment,
            account.balance,
            account.nonce,
            account.isActive
        );
    }

    function isNullifierSpent(bytes32 nullifier) external view returns (bool) {
        return spentNullifiers[nullifier];
    }
}
