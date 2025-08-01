#!/bin/bash
# Hardhat helper functions for easier compilation and filtering

# Function to compile with pipe support
hhc() {
    bash -c 'npx hardhat compile 2>&1' "$@"
}

# Function to compile and show only errors
hhc-errors() {
    bash -c 'npx hardhat compile 2>&1' | grep -i "error"
}

# Function to compile and show only warnings
hhc-warnings() {
    bash -c 'npx hardhat compile 2>&1' | grep -i "warning"
}

# Function to compile and count issues
hhc-count() {
    local output=$(bash -c 'npx hardhat compile 2>&1')
    echo "Compilation Results:"
    echo "Errors: $(echo "$output" | grep -i "error" | wc -l)"
    echo "Warnings: $(echo "$output" | grep -i "warning" | wc -l)"
}

# Export functions for use in subshells
export -f hhc
export -f hhc-errors
export -f hhc-warnings
export -f hhc-count

echo "Hardhat helper functions loaded. Available commands:"
echo "  hhc          - Compile with pipe support"
echo "  hhc-errors   - Show only errors"
echo "  hhc-warnings - Show only warnings"
echo "  hhc-count    - Count errors and warnings"