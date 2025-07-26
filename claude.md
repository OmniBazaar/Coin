# Coin Development

Continue the implementation of the TODO list in the \Coin directory, starting with the most critical priorities. As you work on specific functions and features, develope tests that we can use to validate the code's function, reliability, and security. If Coin\coti-contracts or Coin\test already contain tests that you can use to test your work, do so. If you can adapt existing test for our use, do so. If those tests need to be enhanced or improved, do so. If you find errors in the code, fix them. Use or reuse code that already exists in COTI V2, rather than "re-invent the wheel", whenever it is appropriate. Lint your work as you go along. Run all available tests on your code after you finish coding a contract. Be sure your work will integrate seamlessly with the other contracts that will make up the final, production version of OmniCoin.

In general, we want to implement user functions in such a way that the user will be able to choose to take advantage of privacy features or not. You can set privacy "on" by default.

When possible, modify contracts that already exist in the \Coin\Contracts directory, rather than creating a new file. Study this point before you work on a file and use good judgement. Only create a new file if it is really necessary and will truly result in less work. Remember, the existing contracts compile and have been tested.

In the case where testing finds a function that fails in the hardhat environment, but we know would pass when run in the COTI testnet, let's leave that function in place. I would rather have a test pass on testnet than pass only in hardhat but not be available in testnet.

Create test that actually test the functionality and interoperability of the contracts. If testing shows issues in the code, fix the code. Don't modify the tests for the sake of getting the code to pass the tests. Instead modify the code to pass the tests.

Use minimal mocking and do actual integration of components and modules. Tight integration is critical in OmniBazaar/OmniCoin/OmniWallet/CryptoBazaar. If you must create a mock account, service, component or function, ENSURE that its inclusion and operation do not inhibit or prohibit the functioning of the actual account, service, component or function.

Because we have so many contracts and they are so large, this contract will be bundled with others into "factory" contracts, and those bundled into the final OmniCoin contract. We will deploy this contract on the testnet first for testing. Then deploy for production. So, I think for testing purposes, we want to assume that the MPC dependencies will be provided.

## IMPORTANT: Date and Time Accuracy

**Always use the Bash tool to get accurate timestamps** when updating documentation:

```bash
date "+%Y-%m-%d %H:%M UTC"
```

Do NOT rely on the environment date shown in the system information, as it may be incorrect. Always run the date command before adding timestamps to:
- CURRENT_STATUS.md
- TODO.md
- Any other documentation files
- Commit messages
- Comments in code