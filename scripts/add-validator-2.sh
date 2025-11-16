#!/bin/bash

echo "======================================"
echo "Adding Validator 2 to OmniCoin Network"
echo "======================================"
echo ""
echo "Using:"
echo "  NodeID: NodeID-5AjkqJvhMFK6QJw6wwBHHpuhkE9U88767"
echo "  Weight: 20 (Avalanche max for new validators)"
echo "  Balance: 1 AVAX (for continuous fees)"
echo "  Key: ewoq (pre-funded test key)"
echo ""

# The command expects interaction for duration, so we'll use expect or create input file
cat > /tmp/validator2-input.txt << 'EOF'
720h
EOF

# Run the command with input redirection
cat /tmp/validator2-input.txt | ~/bin/avalanche blockchain addValidator omnicoinevm \
  --node-id "NodeID-5AjkqJvhMFK6QJw6wwBHHpuhkE9U88767" \
  --bls-public-key "0x8eaeec342b4d3ef6fc750f4e4b7124106ab32b6d5b19a8a8275450ed11102139b5631baa6646d4e33fd2a10af9b7751d" \
  --bls-proof-of-possession "0x83bbb14a390b821933eb15b704be5b49e838724d4217a27a4adbc12ce75cfaeef2b69fb6f9b344cc953550df72f2eb5a0875309764932e3aff5ece7ea897ca060321b7543929cf7f7252883b3cb4efaa2986979794bc1633007168f91a7ffba3" \
  --weight 20 \
  --balance 1 \
  --ewoq \
  --fuji

echo ""
echo "======================================"
echo "Checking updated validator list..."
echo "======================================"

~/bin/avalanche blockchain validators omnicoinevm --fuji