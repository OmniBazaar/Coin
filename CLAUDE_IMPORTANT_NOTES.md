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

## Hardhat Pipe Workarounds (NEW)

The issue: Hardhat interprets pipe operators and subsequent commands as positional arguments, causing HH308 errors.

### Solution 1: Simple Wrapper Script

```bash
# Use the provided wrapper script
./scripts/compile-wrapper.sh | grep -i "error"
./scripts/compile-wrapper.sh | grep -i "warning"
```

### Solution 2: Enhanced Wrapper Script

```bash
# Use the enhanced wrapper with options
./scripts/hh-compile.sh --errors    # Show only errors
./scripts/hh-compile.sh --warnings  # Show only warnings
./scripts/hh-compile.sh --summary   # Show errors, warnings, and compilation summary
./scripts/hh-compile.sh --count     # Count errors and warnings
```

### Solution 3: Direct Bash Command

```bash
# Run hardhat in a subshell before piping
bash -c 'npx hardhat compile 2>&1' | grep -i "error"
bash -c 'npx hardhat compile 2>&1' | grep -i "warning"
```

### Solution 4: Helper Functions

```bash
# Source the helper functions
source ./scripts/hardhat-helpers.sh

# Use the convenient functions
hhc | grep "error"      # Compile with pipe support
hhc-errors              # Show only errors
hhc-warnings            # Show only warnings
hhc-count               # Count errors and warnings
```

## Working Pattern

0. Use "solhint" instead of compile to find errors and warnings.
1. Run compilation: `npx hardhat compile` if the purpose is actually to compile
2. Wait for completion (2-3 minutes)
3. If errors appear, fix them
4. Run compilation again to verify

For quick error/warning checks with pipes, use one of the workaround solutions above.

IMPORTANT: Fix all warnings in addition to fixing the errors. Add NatSpec documentation, fix sequencing issues, complexity, line length, and shadow declarations. Check all "not-rely-on-time" instances to be sure the business case really needs them. If so, you may disable the warning with solhint-disable-line comments. Fix every warning you can. Don't put it off for "later".
