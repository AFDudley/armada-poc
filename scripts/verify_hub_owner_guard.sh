#!/usr/bin/env bash
# ABOUTME: Verifies the hub PrivacyPool deploy owner guard (pebble arp-3a7).
# ABOUTME: The hub pool's owner (verification-key authority, issue #349) must not be an
# ABOUTME: address the governance DAO can reach (governor/treasury/wind-down). The hub deploy
# ABOUTME: path offers a dedicated POOL_OWNER_ADDRESS input separate from the deployer.
# ABOUTME:
# ABOUTME: Usage:
# ABOUTME:   scripts/verify_hub_owner_guard.sh --guard-cases  → JSON on stdout
# ABOUTME:   scripts/verify_hub_owner_guard.sh --owner-input → JSON on stdout

set -euo pipefail

# ── Fixed addresses (distinct from the anvil deployer account 0) ─────────────────
GOVERNOR_ADDR="0x0000000000000000000000000000000000000001"
TREASURY_ADDR="0x0000000000000000000000000000000000000002"
WIND_DOWN_ADDR="0x0000000000000000000000000000000000000003"
OWNER_INPUT_ADDR="0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
DEPLOYER_ADDR="0xf39Fd6e51aad88F6F4ce6aB882372366"

PORT=18545
CHAIN_ID=31337
HUB_RPC="http://localhost:${PORT}"

cd "$(dirname "$0")/.."  # repo root

function start_anvil() {
  # Kill any previous instance on the dedicated port
  (lsof -ti:"${PORT}" 2>/dev/null | xargs -r kill -9 || true)
  anvil --port "${PORT}" --chain-id "${CHAIN_ID}" --block-time 1 --accounts 200 >/tmp/anvil_hub.log 2>&1 &
  ANVIL_PID=$!
  # Wait for RPC to come up
  for _ in $(seq 1 30); do
    if curl -s "${HUB_RPC}" -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
  echo "anvil started (pid ${ANVIL_PID})" >&2
}

function setup_local_gov_fixture() {
  # Local governance manifest fixture with real governor/treasury/wind-down addresses
  # so the hub deploy guard has something to compare against.
  cat > deployments/governance-hub.json <<JSON
{
  "chainId": ${CHAIN_ID},
  "deployer": "${DEPLOYER_ADDR}",
  "contracts": {
    "timelockController": "0x1111111111111111111111111111111111111111",
    "armToken": "0x2222222222222222222222222222222222222222",
    "treasury": "${TREASURY_ADDR}",
    "governor": "${GOVERNOR_ADDR}",
    "governorImpl": "0x3333333333333333333333333333333333333333",
    "steward": "0x4444444444444444444444444444444444444444",
    "adapterRegistry": "0x5555555555555555555555555555555555555555",
    "revenueCounter": "0x6666666666666666666666666666666666666666",
    "revenueLock": "0x8888888888888888888888888888888888888888",
    "windDown": "${WIND_DOWN_ADDR}"
  }
}
JSON
}

function run_pool_deploy() {
  # $1 = POOL_OWNER_ADDRESS value
  DEPLOY_ENV=local CCTP_MODE=mock HUB_RPC="${HUB_RPC}" POOL_OWNER_ADDRESS="$1" \
    npx hardhat run scripts/deploy_privacy_pool.ts --network hub
}

function run_cctp_deploy() {
  DEPLOY_ENV=local CCTP_MODE=mock HUB_RPC="${HUB_RPC}" \
    npx hardhat run scripts/deploy_cctp_v3.ts --network hub
}

function expect_exit_nonzero() {
  # Returns 0 (success) when the inner command exits non-zero (i.e. guard refused).
  if run_pool_deploy "$1" >/dev/null 2>&1; then
    echo "FAIL: owner=$1 should have been refused by the hub owner guard" >&2
    return 1
  else
    return 0
  fi
}

case "$1" in
  --guard-cases)
    start_anvil
    setup_local_gov_fixture
    run_cctp_deploy >/dev/null 2>&1
    # 1. owner = governor → guard must refuse
    expect_exit_nonzero "${GOVERNOR_ADDR}"
    # 2. owner = treasury → guard must refuse
    expect_exit_nonzero "${TREASURY_ADDR}"
    # 3. owner = wind-down → guard must refuse
    expect_exit_nonzero "${WIND_DOWN_ADDR}"
    # 4. owner = distinct → deploy must be accepted
    run_pool_deploy "${OWNER_INPUT_ADDR}" >/dev/null 2>&1
    # Emit the result JSON (only JSON on stdout)
    cat <<JSON
{"refused_when_owner_equals_governor": true,
 "refused_when_owner_equals_treasury": true,
 "refused_when_owner_equals_wind_down": true,
 "accepted_when_owner_distinct": true}
JSON
    ;;
  --owner-input)
    start_anvil
    setup_local_gov_fixture
    run_cctp_deploy >/dev/null 2>&1
    run_pool_deploy "${OWNER_INPUT_ADDR}" >/dev/null 2>&1
    # Read the manifest's poolOwner and deployer, and verify owner == input and != deployer
    pool_owner=$(python3 -c "import json;print(json.load(open('deployments/privacy-pool-hub.json'))['poolOwner'])" 2>/dev/null || echo "")
    deployer=$(python3 -c "import json;print(json.load(open('deployments/privacy-pool-hub.json'))['deployer'])" 2>/dev/null || echo "")
    eq_input=false
    eq_deployer=true
    if [ "${pool_owner}" != "${OWNER_INPUT_ADDR}" ] && [ "${pool_owner^l}" != "${OWNER_INPUT_ADDR}" ]; then
      eq_input=false
    else
      eq_input=true
    fi
    if [ "${pool_owner}" = "${deployer}" ]; then
      eq_deployer=true
    else
      eq_deployer=false
    fi
    cat <<JSON
{"owner_equals_input": ${eq_input}, "owner_equals_deployer": ${eq_deployer}}
JSON
    ;;
  *)
    echo "Usage: $0 [--guard-cases|--owner-input]" >&2
    exit 1
    ;;
esac
