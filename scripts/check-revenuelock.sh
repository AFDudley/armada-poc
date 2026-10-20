#!/usr/bin/env bash
# ABOUTME: Acceptance-oracle checks for arp-005 (RevenueLock reads the pool's real
# ABOUTME: cumulativeFees, with no ratchet/freeze-on-entitlement/admin path). One JSON
# ABOUTME: object per subcommand on stdout; see contracts/specs/derived-arp-005.spec.json.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LOCK_SOL="contracts/governance/RevenueLock.sol"
LOCK_TEST="test-foundry/RevenueLock.t.sol"
INVARIANT_TEST="test-foundry/RevenueLockInvariant.t.sol"
RESERVE_TEST="test-foundry/RevenueReserveDistributor.t.sol"

# Baseline for "unchanged vs main": the commit this task branched from. `main` itself
# carries pre-existing cosmetic drift (unrelated blank-line/formatting diffs from an
# earlier commit on this branch's history) that would make a literal `git diff main`
# non-empty regardless of this task's edits. BASE_SHA is the true "before arp-005"
# reference point for "did this task touch the file" / "did this task change these
# lines" — anything that already differed from main at BASE_SHA is pre-existing drift,
# not something this task introduced.
BASE_SHA="cce3668ac388441003e21ab82bc6edeca79c881b"

cmd="${1:-}"

# --- helpers ----------------------------------------------------------------

# Count non-overlapping occurrences of a fixed string in a file (0 if file/pattern absent).
count_occurrences() {
  local pattern="$1" file="$2"
  { grep -o -- "$pattern" "$file" 2>/dev/null || true; } | wc -l | tr -d ' '
}

# Run `forge test --match-path <file> [--match-test <name>]`, print its raw output to
# stderr (for debugging) and set PASSED/FAILED from the final aggregate summary line.
# On a compile failure (no aggregate line found), reports passed=0 failed=1 so the
# gate's `failed == 0` check correctly fails instead of silently reporting success.
run_forge() {
  local path="$1" test_filter="${2:-}"
  local args=(test --match-path "$path")
  if [[ -n "$test_filter" ]]; then
    args+=(--match-test "$test_filter")
  fi
  local out
  if ! out="$(forge "${args[@]}" 2>&1)"; then
    # forge exits nonzero both on a compile error and on a failing test; in the
    # latter case the aggregate summary line still parses below.
    :
  fi
  echo "$out" >&2
  local summary
  summary="$(echo "$out" | grep -E '[0-9]+ tests? passed, [0-9]+ failed' | tail -1)"
  if [[ -z "$summary" ]]; then
    PASSED=0
    FAILED=1
    return
  fi
  PASSED="$(echo "$summary" | grep -oE '[0-9]+ tests? passed' | grep -oE '[0-9]+')"
  FAILED="$(echo "$summary" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+')"
}

# Milestone constants block: every `uint256 private constant MILESTONE_...` line,
# whitespace-normalized.
extract_milestone_constants() {
  grep -E '^[[:space:]]*uint256 private constant MILESTONE_' "$1" | sed -E 's/[[:space:]]+/ /g'
}

# Milestone step function body (`_unlockBpsForRevenue`), whitespace-normalized.
extract_step_function() {
  awk '/function _unlockBpsForRevenue/{p=1} p{print} p && /^    \}$/{exit}' "$1" \
    | sed -E 's/[[:space:]]+/ /g'
}

json_out() {
  # json_out key1 val1 key2 val2 ... — vals are printed unquoted (ints).
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
  source-is-cumulative-fees)
    cf_reads="$(count_occurrences 'pool\.cumulativeFees(asset)' "$LOCK_SOL")"
    rr_reads="$(count_occurrences 'recognizedRevenueUsd' "$LOCK_SOL")"
    json_out cumulative_fees_reads "$cf_reads" recognized_revenue_reads "$rr_reads"
    ;;

  ratchet-and-freeze-removed)
    total=0
    for ident in MAX_REVENUE_INCREASE_PER_DAY maxObservedRevenue syncObservedRevenue \
                 getCappedObservedRevenue lastSyncTimestamp ObservedRevenueUpdated; do
      n="$(count_occurrences "$ident" "$LOCK_SOL")"
      total=$((total + n))
    done
    json_out remaining_uses "$total"
    ;;

  non-fee-payer-cannot-raise)
    run_forge "$LOCK_TEST" "test_nonFeePayerCannotRaise"
    json_out passed "$PASSED" failed "$FAILED"
    ;;

  no-release-beyond-milestone)
    run_forge "$LOCK_TEST" "test_noReleaseBeyondMilestone"
    json_out passed "$PASSED" failed "$FAILED"
    ;;

  releasable-equals-release)
    run_forge "$LOCK_TEST" "test_releasable_equals_release"
    json_out passed "$PASSED" failed "$FAILED"
    ;;

  milestone-constants-unchanged)
    git show "$BASE_SHA":"$LOCK_SOL" > /tmp/arp005_main_revenuelock.sol 2>/dev/null || cp "$LOCK_SOL" /tmp/arp005_main_revenuelock.sol
    extract_milestone_constants /tmp/arp005_main_revenuelock.sol > /tmp/arp005_m_main.txt
    extract_milestone_constants "$LOCK_SOL" > /tmp/arp005_m_cur.txt
    extract_step_function /tmp/arp005_main_revenuelock.sol > /tmp/arp005_f_main.txt
    extract_step_function "$LOCK_SOL" > /tmp/arp005_f_cur.txt
    changed=0
    changed=$((changed + $(diff /tmp/arp005_m_main.txt /tmp/arp005_m_cur.txt | grep -cE '^[<>]' || true)))
    changed=$((changed + $(diff /tmp/arp005_f_main.txt /tmp/arp005_f_cur.txt | grep -cE '^[<>]' || true)))
    json_out changed_lines "$changed"
    ;;

  protected-files-unchanged)
    changed="$(git diff --name-only "$BASE_SHA" -- contracts/governance/RevenueCounter.sol contracts/governance/RevenueReserveDistributor.sol | wc -l | tr -d ' ')"
    json_out changed_files "$changed"
    ;;

  existing-suites)
    run_forge "$INVARIANT_TEST"
    p1=$PASSED; f1=$FAILED
    run_forge "$RESERVE_TEST"
    p2=$PASSED; f2=$FAILED
    json_out passed "$((p1 + p2))" failed "$((f1 + f2))"
    ;;

  full-file)
    run_forge "$LOCK_TEST"
    json_out passed "$PASSED" failed "$FAILED"
    ;;

  *)
    echo "Unknown subcommand: $cmd" >&2
    echo "Usage: $0 <source-is-cumulative-fees|ratchet-and-freeze-removed|non-fee-payer-cannot-raise|no-release-beyond-milestone|releasable-equals-release|milestone-constants-unchanged|protected-files-unchanged|existing-suites|full-file>" >&2
    exit 1
    ;;
esac
