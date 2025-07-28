# IMPORTANT NOTES FOR CLAUDE

IMPORTANT: Use "solhint" instead of compile to find errors and warnings. It is faster and less prone to issues.

## Hardhat Compilation

1. **NEVER use pipes or additional commands with `npx hardhat compile`**
   - ❌ WRONG: `npx hardhat compile | grep error`
   - ❌ WRONG: `npx hardhat compile 2>&1 | head -50`
   - ✅ CORRECT: `npx hardhat compile`

2. **Compilation takes time**
   - We're compiling 36+ Solidity files
   - This WILL take several minutes
   - Don't timeout after 30-60 seconds
   - Use at least 120000ms (2 minutes) timeout or more

3. **To check compilation results**
   - Run `npx hardhat compile` by itself
   - Wait for it to complete
   - THEN check for errors in the output

## Working Pattern

0. Use "solhint" instead of compile to find errors and warnings.
1. Run compilation: `npx hardhat compile` if the purpose is actually to compile
2. Wait for completion (2-3 minutes)
3. If errors appear, fix them
4. Run compilation again to verify

This is the ONLY reliable way to compile and check for errors.

IMPORTANT: Fix all warnings in addition to fixing the errors. Add NatSpec documentation, fix sequencing issues, complexity, line length, and shadow declarations. Check all "not-rely-on-time" instances to be sure the business case really needs them. If so, you may disable the warning with solhint-disable-line comments. Fix every warning you can. Don't put it off for "later".