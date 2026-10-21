#!/usr/bin/env bash
# ABOUTME: Acceptance-oracle checks for arp-67a (governance manifest + Baal-era wiring).
# ABOUTME: Seven subcommands; each prints one JSON object. On-chain subcommands start a local
# ABOUTME: anvil, run the deploy scripts in dependency order, and query the deployed chain.
# ABOUTME: See contracts/specs/derived-arp-67a.spec.json.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

GOV_MANIFEST="deployments/governance-hub.json"
GOV_DOC="specs/GOVERNANCE.md"
VENDORED_LIBS=(lib/baal lib/safe-contracts lib/hedgey)
LOCK_SOL="contracts/governance/RevenueLock.sol"

ANVIL_PORT="${ANVIL_PORT:-18646}"
export HUB_RPC="http://127.0.0.1:${ANVIL_PORT}"

# A local deploy must still produce a complete launch-path manifest, so configure the optional
# RevenueReserveDistributor (c2 lists revenueReserveDistributor as a required field) and a single
# direct beneficiary whose amount plus the reserve equals ARM_REVENUE_LOCK_ALLOCATION (2,400,000).
# All addresses are non-Anvil so the deploy guards accept them.
export REVENUE_RESERVE_ALLOCATOR="${REVENUE_RESERVE_ALLOCATOR:-0x1111111111111111111111111111111111111111}"
export REVENUE_RESERVE_AMOUNT="${REVENUE_RESERVE_AMOUNT:-400000}"
if [[ -z "${REVENUE_LOCK_BENEFICIARIES_JSON:-}" ]]; then
  REVENUE_LOCK_BENEFICIARIES_JSON='[{"address":"0x3333333333333333333333333333333333333333","amount":"2000000","label":"team"}]'
fi
export REVENUE_LOCK_BENEFICIARIES_JSON

cmd="${1:-}"

# --- helpers ----------------------------------------------------------------

ANVIL_PID=""
start_anvil() {
  anvil --port "${ANVIL_PORT}" --chain-id 31337 --silent >/dev/null 2>&1 &
  ANVIL_PID=$!
  local _attempt
  for _attempt in $(seq 1 60); do
    if cast block-number --rpc-url "$HUB_RPC" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  echo "anvil did not start on port ${ANVIL_PORT}" >&2
  return 1
}

stop_anvil() {
  if [[ -n "$ANVIL_PID" ]]; then
    kill "$ANVIL_PID" 2>/dev/null || true
  fi
}
trap stop_anvil EXIT

# Run a deploy script on the hub network; its own logs go to stderr.
run_script() {
  npx hardhat run "scripts/$1.ts" --network hub >&2
}

# Deploy the governance prerequisites: CCTP mocks, the privacy pool, governance and the Baal summon.
deploy_governance_stack() {
  run_script deploy_cctp_v3
  run_script deploy_privacy_pool
  run_script deploy_governance
}

deploy_summon() {
  run_script summon-baal-safe
}

# --- subcommands ------------------------------------------------------------

case "$cmd" in
  manifest-exists)
    # c1: after the governance deploy, the manifest exists and can be loaded.
    start_anvil
    deploy_governance_stack
    if [[ -f "$GOV_MANIFEST" ]]; then
      python3 -c "import json; json.load(open('$GOV_MANIFEST'))"
      echo '{"manifest_exists": true}'
    else
      echo '{"manifest_exists": false}'
    fi
    ;;

  manifest-contents)
    # c2: manifest.treasury is the Safe (equals the timelock/governor entries), the required
    #     entries are present, and no CUSTOM governor, timelock or wind-down entry exists
    #     (governor and timelockController are allowed only when they equal the Safe treasury).
    start_anvil
    deploy_governance_stack
    python3 - "$GOV_MANIFEST" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
contracts = data.get("contracts", {})
treasury = contracts.get("treasury", "")
required = [
    "armToken",
    "revenueLock",
    "adapterRegistry",
    "shieldPauseController",
    "revenueReserveDistributor",
]
missing = [f for f in required if not contracts.get(f)]
# The treasury must be the Safe, which is also the timelock and the governance executor.
treasury_is_safe = bool(treasury) and treasury == contracts.get(
    "timelockController"
) and treasury == contracts.get("governor")
# A dropped-governance field is a wind-down entry, or a governor/timelock that is a CUSTOM
# contract (i.e. an address other than the Safe treasury).
dropped = False
if "windDown" in contracts:
    dropped = True
if contracts.get("governor") and contracts.get("governor") != treasury:
    dropped = True
if contracts.get("timelockController") and contracts.get("timelockController") != treasury:
    dropped = True
print(json.dumps({
    "treasury_is_safe": treasury_is_safe,
    "missing_required_fields": len(missing),
    "has_dropped_governance_fields": dropped,
}))
PY
    ;;

  shaman-and-burner)
    # c3: Baal.shamans(ShieldedRagequit) is the manager role, and
    #     ArmadaToken.authorizedBurner(ShieldedRagequit) is true.
    start_anvil
    deploy_governance_stack
    deploy_summon
    npx hardhat run scripts/query-governance-state.ts --network hub
    ;;

  safe-reuse)
    # c5: the Safe is ArmadaToken's timelock and the Baal summon reuses it (one Safe total).
    start_anvil
    deploy_governance_stack
    deploy_summon
    npx hardhat run scripts/query-governance-state.ts --network hub
    ;;

  readers-run)
    # c4: after the governance deploy, each of the six reader scripts runs to completion.
    #     The prerequisites (CCTP, Aave mock, governance) are deployed first; then the six
    #     readers run in dependency order and each success is counted.
    start_anvil
    cohort_file="$(mktemp)"
    printf '[{"address":"0x2222222222222222222222222222222222222222","amount":"1","label":"local cohort member"}]' > "$cohort_file"
    export REVENUE_LOCK_COHORT_NAME="local"
    export REVENUE_LOCK_COHORT_FILE="$cohort_file"

    readers_run=0
    readers_failed=0
    count_reader() {
      if npx hardhat run "scripts/$1.ts" --network hub >&2; then
        readers_run=$((readers_run + 1))
      else
        readers_failed=$((readers_failed + 1))
      fi
    }

    # Prerequisites that are not among the six counted readers.
    run_script deploy_cctp_v3
    run_script deploy_aave_mock
    # Reader 1: the privacy pool (also a prerequisite for governance's RevenueLock).
    count_reader deploy_privacy_pool
    run_script deploy_governance
    # Readers 2-6.
    count_reader deploy_yield
    count_reader link_privacy_pool
    count_reader deploy_fee_module
    count_reader deploy_crowdfund
    count_reader deploy_revenue_lock_cohort

    rm -f "$cohort_file"
    echo "{\"readers_run\": ${readers_run}, \"readers_failed\": ${readers_failed}}"
    ;;

  governance-doc)
    # c6: specs/GOVERNANCE.md says the Safe is the treasury, the Baal is its sole owner, and
    #     ShieldedRagequit is the one exit.
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
    echo "{\"doc_states_safe_treasury\": ${doc_states_safe_treasury}, \"doc_states_baal_sole_owner\": ${doc_states_baal_sole_owner}, \"doc_states_ragequit_one_exit\": ${doc_states_ragequit_one_exit}}"
    ;;

  vendored-unchanged)
    # c7: the vendored Baal, Safe and Hedgey code is unchanged against the integration base,
    #     and RevenueLock still reads the pool cumulativeFees.
    base_sha="$(git rev-parse integrated 2>/dev/null || git rev-parse HEAD~1)"
    vendored_files_changed=$(git diff --name-only "$base_sha" -- "${VENDORED_LIBS[@]}" 2>/dev/null | wc -l | tr -d ' ')
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
