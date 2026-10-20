#!/usr/bin/env bash
# ABOUTME: Verifies the hub PrivacyPool deploy owner guard (pebble arp-b11.2).
# ABOUTME: The hub pool owner (verification-key authority, issue #349) must not be an
# ABOUTME: address the Baal/Safe governance can direct: the Baal, the Safe (treasury),
# ABOUTME: the ShieldedRagequit shaman, or the ARM token (lab book decision 8). The deploy
# ABOUTME: offers a dedicated POOL_OWNER_ADDRESS input separate from the deployer and
# ABOUTME: refuses before the initialize transaction if the owner is a forbidden address.
# ABOUTME:
# ABOUTME: Usage:
# ABOUTME:   scripts/verify_hub_owner_guard.sh --guard-cases  → JSON on stdout
# ABOUTME:   scripts/verify_hub_owner_guard.sh --owner-input  → JSON on stdout

set -euo pipefail

# ── Forbidden-owner fixture addresses (derived at runtime) ─────────────────────
# derive_accounts() reads these from the live anvil (cast rpc eth_accounts) AFTER
# start_anvil, so no well-known anvil address is hardcoded in this deploy-path
# script — scripts/check-anvil-addresses.sh rejects literal anvil addresses.
# Real signers stand in for the governance contracts, so a deploy the guard does
# NOT refuse still runs its owner-signed ops to completion: the red baseline
# shows a forbidden owner fully ACCEPTED, not a failure for an unrelated reason.
DEPLOYER_ADDR=""      # anvil account[0], the deployer
OWNER_INPUT_ADDR=""   # anvil account[1], a dedicated non-governance owner
BAAL_ADDR=""          # anvil account[2], the Baal
SAFE_ADDR=""          # anvil account[3], the Safe (treasury/avatar)
SHAMAN_ADDR=""        # anvil account[4], the ShieldedRagequit shaman
ARM_ADDR=""           # anvil account[5], the ARM token

PORT=18545
CHAIN_ID=31337
HUB_RPC="http://localhost:${PORT}"
ANVIL_PID=""
ANVIL_LOG="./.anvil_hub_owner_guard.log"  # repo-local; never /tmp

cd "$(dirname "$0")/.."  # repo root

function cleanup() {
  [ -n "${ANVIL_PID}" ] && kill -9 "${ANVIL_PID}" 2>/dev/null || true
  rm -f "${ANVIL_LOG}" 2>/dev/null || true
}
trap cleanup EXIT

function start_anvil() {
  (lsof -ti:"${PORT}" 2>/dev/null | xargs -r kill -9 || true)
  anvil --port "${PORT}" --chain-id "${CHAIN_ID}" --block-time 1 --accounts 200 \
    >"${ANVIL_LOG}" 2>&1 &
  ANVIL_PID=$!
  for _ in $(seq 1 30); do
    if cast block-number --rpc-url "${HUB_RPC}" >/dev/null 2>&1; then
      echo "anvil started (pid ${ANVIL_PID})" >&2
      return 0
    fi
    sleep 1
  done
  echo "FAIL: anvil did not come up on ${PORT}" >&2
  exit 1
}

function derive_accounts() {
  # Read the six signer addresses from the live anvil, so no well-known anvil
  # address is a literal in this deploy-path script (check-anvil-addresses.sh).
  local accts
  accts=$(cast rpc eth_accounts --rpc-url "${HUB_RPC}")
  pick() { echo "${accts}" | python3 -c "import json,sys;print(json.load(sys.stdin)[$1])"; }
  DEPLOYER_ADDR=$(pick 0)
  OWNER_INPUT_ADDR=$(pick 1)
  BAAL_ADDR=$(pick 2)
  SAFE_ADDR=$(pick 3)
  SHAMAN_ADDR=$(pick 4)
  ARM_ADDR=$(pick 5)
}

function setup_fixture_manifests() {
  mkdir -p deployments
  # The Baal/Safe deploy manifest: the four addresses the owner guard reads.
  cat > deployments/baal-safe-hub.json <<JSON
{
  "chainId": ${CHAIN_ID},
  "deployer": "${DEPLOYER_ADDR}",
  "deployBlock": 0,
  "contracts": {
    "safe": "${SAFE_ADDR}",
    "safeTemplate": "0x00000000000000000000000000000000000000B1",
    "baal": "${BAAL_ADDR}",
    "baalTemplate": "0x00000000000000000000000000000000000000B2",
    "armToken": "${ARM_ADDR}",
    "lootToken": "0x00000000000000000000000000000000000000B3",
    "multisend": "0x00000000000000000000000000000000000000B4",
    "shieldedRagequit": "${SHAMAN_ADDR}"
  },
  "timestamp": "fixture"
}
JSON
  # The governance manifest: the pool deploy reads treasury (the Safe) for the pool's
  # own immutable treasury init arg; the guard also reads treasury and armToken.
  cat > deployments/governance-hub.json <<JSON
{
  "chainId": ${CHAIN_ID},
  "deployer": "${DEPLOYER_ADDR}",
  "deployBlock": 0,
  "contracts": {
    "treasury": "${SAFE_ADDR}",
    "armToken": "${ARM_ADDR}",
    "governor": "${SAFE_ADDR}",
    "timelockController": "${SAFE_ADDR}"
  },
  "config": { "totalSupply": "0" },
  "timestamp": "fixture"
}
JSON
}

function run_cctp_deploy() {
  DEPLOY_ENV=local CCTP_MODE=mock HUB_RPC="${HUB_RPC}" \
    npx hardhat run scripts/deploy_cctp_v3.ts --network hub
}

function run_pool_deploy() {
  # $1 = POOL_OWNER_ADDRESS value
  DEPLOY_ENV=local CCTP_MODE=mock HUB_RPC="${HUB_RPC}" POOL_OWNER_ADDRESS="$1" \
    npx hardhat run scripts/deploy_privacy_pool.ts --network hub
}

function expect_refused() {
  # Returns 0 when the pool deploy exits non-zero (the owner guard refused).
  if run_pool_deploy "$1" >/dev/null 2>&1; then
    echo "FAIL: owner=$1 should have been refused by the hub owner guard" >&2
    return 1
  fi
  return 0
}

case "${1:-}" in
  --guard-cases)
    start_anvil
    derive_accounts
    setup_fixture_manifests
    run_cctp_deploy >/dev/null 2>&1
    expect_refused "${BAAL_ADDR}"
    expect_refused "${SAFE_ADDR}"
    expect_refused "${SHAMAN_ADDR}"
    expect_refused "${ARM_ADDR}"
    # A dedicated owner must be accepted.
    run_pool_deploy "${OWNER_INPUT_ADDR}" >/dev/null 2>&1
    cat <<JSON
{"refused_when_owner_equals_baal": true,
 "refused_when_owner_equals_safe": true,
 "refused_when_owner_equals_shaman": true,
 "refused_when_owner_equals_arm_token": true,
 "accepted_when_owner_dedicated": true}
JSON
    ;;
  --owner-input)
    start_anvil
    derive_accounts
    setup_fixture_manifests
    run_cctp_deploy >/dev/null 2>&1
    run_pool_deploy "${OWNER_INPUT_ADDR}" >/dev/null 2>&1
    pool_owner=$(python3 -c "import json;print(json.load(open('deployments/privacy-pool-hub.json'))['poolOwner'])" 2>/dev/null || echo "")
    deployer=$(python3 -c "import json;print(json.load(open('deployments/privacy-pool-hub.json'))['deployer'])" 2>/dev/null || echo "")
    eq_input=false
    if [ "${pool_owner,,}" = "${OWNER_INPUT_ADDR,,}" ]; then eq_input=true; fi
    eq_deployer=true
    if [ "${pool_owner,,}" != "${deployer,,}" ]; then eq_deployer=false; fi
    cat <<JSON
{"owner_equals_input": ${eq_input}, "owner_equals_deployer": ${eq_deployer}}
JSON
    ;;
  *)
    echo "Usage: $0 [--guard-cases|--owner-input]" >&2
    exit 1
    ;;
esac
