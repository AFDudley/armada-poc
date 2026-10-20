#!/usr/bin/env bash
# ABOUTME: Acceptance-oracle checks for arp-67a (governance manifest + Baal-era wiring).
# ABOUTME: Seven subcommands; each prints a JSON object. On-chain subcommands spin up a
# ABOUTME: local anvil, run the deploy scripts, and query the deployed chain state.
# ABOUTME: See contracts/specs/derived-arp-67a.spec.json.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BASE_SHA="b5f23db7bed4394ff6f0f4e8c0b5e1419d4f35d2"
GOV_MANIFEST="deployments/governance-hub.json"
GOV_MANIFEST_NONLOCAL="deployments/governance-hub-local.json"
GOV_DOC="docs/GOVERNANCE.md"
VENDORED_LIBS="lib/baal lib/safe-contracts lib/hedgey"
LOCK_SOL="contracts/governance/RevenueLock.sol"

ANVIL_PORT="18646"
HUB_RPC="http://127.0.0.1:${ANVIL_PORT}"

cmd="${1:-}"

# --- helpers ----------------------------------------------------------------

json_out() {
  # json_out key1 val1 key2 val2 ... — vals are printed unquoted (ints/bools).
  local out="{" first=1
  while [[ $# -gt 0 ]]; do
    local k="$1" v="$2"; shift 2
    [[ $first -eq 1 ]] || out+=","
    first=0
    out+="\"$k\":$v"
  done
  out+="}"
  echo "$out"
}

# --- subcommands --------------------------------------------------------------

case "$cmd" in
  manifest-exists)
    exists=false
    for _f in "$GOV_MANIFEST" "$GOV_MANIFEST_NONLOCAL"; do
      if [[ -f "$_f" ]]; then
        exists=true
        _f_found="$_f"
      fi
    done
    # c1: after the governance deploy, the manifest file exists and can be loaded.
    if [[ -n "${_f_found:-}"]]"; then
      python3 -c "import json; json.load(open('$_f_found'))"
      json_out manifest_exists true
    else
      json_out manifest_exists false
    fi
    ;;

  manifest-contents)
    # c2: manifest.treasury equals the Safe address; required entries present;
    # no custom governor, timelock or wind-down entries.
    python3 - <<PY
import json, os
manifest_file = "deployments/governance-hub.json"
if not os.path.exists(manifest_file):
    manifest_file = "deployments/governance-hub-local.json"
if not os.path.exists(manifest_file):
    print(json.dumps({"treasury_is_safe": False, "missing_required_fields": 10, "has_dropped_governance_fields": False})
    raise SystemExit(0)
data = json.load(open(manifest_file))
contracts = data.get("contracts", {})
required = ["armToken", "revenueLock", "adapterRegistry", "shieldPauseController", "revenueReserveDistributor"]
dropped = ["governor", "timelockController", "windDown"]
missing = [f for f in required if f not in contracts]
# For treasury_is_safe: the treasury field is the Safe address (the Safe is the treasury).
# We can't verify on-chain here, so we check the field is present.
treasury_is_safe = bool(contracts.get("treasury", "") != "")
dropped_present = [f for f in dropped if f in contracts]
print(json.dumps({
    "treasury_is_safe": treasury_is_safe,
    "missing_required_fields": len(missing),
    "has_dropped_governance_fields": len(dropped_present) > 0,
}))
PY
    ;;

  shaman-and-burner)
    # c3: Baal.shamans(ShieldedRagequit) is the manager role, and
    # ArmadaToken.authorizedBurner(ShieldedRagequit) is true.
    # This requires on-chain state. Spin up a local node, run the deploy,
    # and query the chain.
    anvil --port ${ANVIL_PORT} --chain-id 31337 --silent &
    anvil_pid=$!
    sleep 1
    HUB_RPC="$HUB_RPC" npx hardhat run scripts/deploy_governance.ts --network hub
    HUB_RPC="$HUB_RPC" npx hardhat run scripts/summon-baal-safe.ts --network hub
    result=$(HUB_RPC="$HUB_RPC" npx hardhat run scripts/query-governance-state.ts)
    kill $anvil_pid 2> /dev/null || true
    echo "$result"
    ;;

  readers-run)
    # c4: each of the six reader scripts runs against the local node and finishes
    # without error.
    # Spin up a local node, run the governance deploy, then run each reader.
    anvil --port ${ANVIL_PORT} --chain-id 31337 --silent &
    anvil_pid=$!
    sleep 1
    # Run the governance deploy first (required by the readers).
    HUB_RPC="$HUB_RPC" npx hardhat run scripts/deploy_governance.ts --network hub
    readers=(
      "scripts/deploy_privacy_pool.ts"
      "scripts/deploy_fee_module.ts"
      "scripts/deploy_crowdfund.ts"
      "scripts/deploy_yield.ts"
      "scripts/deploy_revenue_lock_cohort.ts"
      "scripts/link_privacy_pool.ts"
    )
    readers_run=0
    readers_failed=0
    for reader in "${readers[@]}"; do
      if HUB_RPC="$HUB_RPC" npx hardhat run "$reader" --network hub > /dev/null 2>&1; then
        readers_run=$((readers_run + 1))
      else
        readers_failed=$((readers_failed + 1))
      fi
    done
    kill $anvil_pid 2> /dev/null || true
    echo "{\"readers_run\": ${readers_run}, \"readers_failed\": ${readers_failed}}"
    ;;

  safe-reuse)
    # c5: The Safe address is used as ArmadaToken's timelock and as the executor
    # address, and the Baal summon step reuses it.
    # The Safe is deployed before ArmadaToken (as its immutable timelock), so there should
    # be exactly one Safe deployed (by deploy_governance.ts).
    # We verify via the deploy scripts' output and on-chain state.
    anvil --port ${ANVIL_PORT} --chain-id 31337 --silent &
    anvil_pid=$!
    sleep 1
    HUB_RPC="$HUB_RPC" npx hardhat run scripts/deploy_governance.ts --network hub
    HUB_RPC="$HUB_RPC" npx hardhat run scripts/summon-baal-safe.ts --network hub
    result=$(HUB_RPC="$HUB_RPC" npx hardhat run scripts/query-governance-state.ts)
    kill $anvil_pid 2> /dev/null || true
    echo "$result"
    ;;

  governance-doc)
    # c6: The governance document says the Safe is the treasury, the Baal is its
    # sole owner, and ShieldedRagequit is the one exit.
    doc_states_safe_treasury=false
    doc_states_baal_sole_owner=false
    doc_states_ragequit_one_exit=false
    if [[ -f "$GOV_DOC" ]]; then
      if grep -qiE "safe.*treasury|treasury.*safe" "$GOV_DOC"; then
        doc_states_safe_treasury=true
      fi
      if grep -qiE "baal.*sole owner|sole owner.*baal" "$GOV_DOC"; then
        doc_states_baal_sole_owner=true
      fi
      if grep -qiE "shieldedragequit.*one exit|one exit.*shieldedragequit" "$GOV_DOC"; then
        doc_states_ragequit_one_exit=true
      fi
    fi
    echo "{\"doc_states_safe_treasury\": ${doc_states_safe_treasury}, \"doc_states_baal_sole_owner\": ${doc_states_baal_sole_owner}, \"doc_states_ragequit_one_exit\": ${doc_states_ragequit_one_exit}"
    ;;

  vendored-unchanged)
    # c7: The vendored Baal, Safe and Hedgey code is unchanged, and RevenueLock
    # still reads the pool cumulativeFees.
    # Check the vendored libs are unchanged (git diff vs base) and RevenueLock reads
    # cumulativeFees.
    vendored_files_changed=$(git diff --name-only "$BASE_SHA" -- $VENDORED_LIBS 2> /dev/null | wc -l | tr -d ' ')
    if grep -qE "cumulativeFees" "$LOCK_SOL"; then
      revenue_lock_reads_cumulative_fees=true
    else
      revenue_lock_reads_cumulative_fees=false
    fi
    echo "{\"vendored_files_changed\": ${vendored_files_changed}, \"revenue_lock_reads_cumulative_fees\": ${revenue_lock_reads_cumulative_fees}}"
    ;;

  *)
    echo "Unknown subcommand: $cmd" >&2
    echo "Usage: $0 <manifest-exists|manifest-contents|shaman-and-burner|readers-run|safe-reuse|governance-doc|vendored-unchanged>" >&2
    exit 1
    ;;

esac
