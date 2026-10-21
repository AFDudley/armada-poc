#!/usr/bin/env bash
# ABOUTME: Gate probe for arp-63a.4 (c6): runs the production crowdfund deploy flow on a
# ABOUTME: local hub chain (CCTP + Baal Safe + PrivacyPool + Crowdfund), then reads the
# ABOUTME: deployed crowdfund's active-window length and launch-team invite period. Emits
# ABOUTME: JSON: {"window_seconds": 1814400, "launch_team_invite_seconds": 1814400}.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

ANVIL_PORT=${ANVIL_PORT:-8545}
CHAIN_ID=${CHAIN_ID:-31337}

# Start a local hub chain (anvil) and run the production deploy flow.
lsof -ti:$ANVIL_PORT | xargs -r kill -9 2>/dev/null
sleep 1

anvil --port "$ANVIL_PORT" --chain-id "$CHAIN_ID" --block-time 1 --accounts 200 &
HUB_PID=$!
sleep 2

# Clean prior local deployment artifacts so the flow runs fresh.
rm -f deployments/governance-hub.json deployments/hub-v3.json deployments/privacy-pool-hub.json deployments/crowdfund-hub.json

# Production flow: CCTP (USDC) -> PrivacyPool -> Governance (Baal Safe) -> Crowdfund.
npx hardhat run scripts/deploy_cctp_v3.ts --network hub > /dev/null 2>&1
npx hardhat run scripts/deploy_privacy_pool.ts --network hub > /dev/null 2>&1
npx hardhat run scripts/deploy_governance.ts --network hub > /dev/null 2>&1
npx hardhat run scripts/deploy_crowdfund.ts --network hub > /dev/null 2>&1

# Query the deployed crowdfund's window and invite periods and print the JSON report.
QUERY_JSON=$(npx hardhat run scripts/query_crowdfund_window.ts 2>/dev/null)

# Cleanup the hub chain.
kill "$HUB_PID" 2>/dev/null

printf '%s\n' "$QUERY_JSON"
