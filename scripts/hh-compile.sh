#!/bin/bash
# Enhanced Hardhat compile wrapper with filtering options

# Default behavior - run compile with all output
if [ $# -eq 0 ]; then
    npx hardhat compile 2>&1
    exit $?
fi

# Handle different options
case "$1" in
    --errors)
        npx hardhat compile 2>&1 | grep -i "error"
        ;;
    --warnings)
        npx hardhat compile 2>&1 | grep -i "warning"
        ;;
    --summary)
        npx hardhat compile 2>&1 | grep -E "(error|warning|Compiled|Nothing to compile)"
        ;;
    --count)
        echo "Errors: $(npx hardhat compile 2>&1 | grep -i "error" | wc -l)"
        echo "Warnings: $(npx hardhat compile 2>&1 | grep -i "warning" | wc -l)"
        ;;
    *)
        echo "Usage: $0 [--errors|--warnings|--summary|--count]"
        echo "  --errors    Show only errors"
        echo "  --warnings  Show only warnings"
        echo "  --summary   Show errors, warnings, and compilation summary"
        echo "  --count     Count errors and warnings"
        exit 1
        ;;
esac