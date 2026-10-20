#!/usr/bin/env bash
# ABOUTME: G3/arp-a76 c10 — the exit-proof conservation oracle.
# ABOUTME: 1) runs a ShieldedRagequit exit (creates the contract-owned payout note at the
# ABOUTME:    caller's npk via PrivacyPool.transactOwned).
# ABOUTME: 2) builds a spend of that payout note with @armada/sdk planTransfer + prove.
# ABOUTME: 3) submits the spend on-chain via PrivacyPool.transact — the deployed Verifier
# ABOUTME:    accepts the armada-built Groth16 proof.
# ABOUTME: 4) asserts conservation: the value the spend consumes equals the sum of its outputs.
# Usage:
#   bash scripts/verify-ragequit-exit-proof.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

echo "=== G3/arp-a76 c10: ShieldedRagequit exit-proof conservation oracle ==="

# The c10 harness requires a local chain with the pool + ARM + ShieldedRagequit deployed
# (via `npm run setup`). The harness runs the exit, builds the spend, and submits transact on-chain.
echo "Running the c10 harness (planTransfer + prove + on-chain transact + conservation check)..."
npx hardhat run scripts/verify-ragequit-exit-proof.ts --network hub
