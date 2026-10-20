#!/usr/bin/env python3
"""
ABOUTME: Verifies the G2 Baal + Safe summon (docs/tasks/G2-baal-safe-summon.md,
ABOUTME: contracts/specs/derived-arp-1f1.spec.json): vendoring + commit pinning
ABOUTME: of lib/safe-contracts and lib/baal, setup-chain wiring of
ABOUTME: deploy:governance-baal after deploy:governance, a live fixturenet deploy's
ABOUTME: Safe-ownership/threshold/shares-token facts and owner-history (no human
ABOUTME: Safe owner at any step), and the BaalSafeSummon.t.sol forge test result.

Usage:
  verify-baal-safe-summon.py --report vendoring
  verify-baal-safe-summon.py --report wiring
  verify-baal-safe-summon.py --report safe
  verify-baal-safe-summon.py --report shares-token
  verify-baal-safe-summon.py --report owner-history
  verify-baal-safe-summon.py --report forge-test
"""
import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PACKAGE_JSON = REPO_ROOT / "package.json"
SUMMON_SCRIPT = REPO_ROOT / "scripts" / "summon-baal-safe.ts"
LIB_SAFE = REPO_ROOT / "lib" / "safe-contracts"
LIB_BAAL = REPO_ROOT / "lib" / "baal"
FORGE_TEST_PATH = REPO_ROOT / "test-foundry" / "BaalSafeSummon.t.sol"

ANVIL_PORT = 18645  # dedicated port; avoids clobbering any already-running dev anvil on 8545.
HUB_RPC = f"http://127.0.0.1:{ANVIL_PORT}"

FORGE_TIMEOUT = 300
DEPLOY_TIMEOUT = 300
ANVIL_READY_TIMEOUT = 20


# ---------------------------------------------------------------------------
# c1 — vendoring
# ---------------------------------------------------------------------------


def _vendored_and_pinned(lib_dir: Path, sentinel_contract: Path) -> bool:
    pin_file = lib_dir / "pin.json"
    if not lib_dir.is_dir() or not sentinel_contract.is_file() or not pin_file.is_file():
        return False
    try:
        pin = json.loads(pin_file.read_text())
    except (OSError, json.JSONDecodeError):
        return False
    commit = pin.get("commit")
    return isinstance(commit, str) and re.fullmatch(r"[0-9a-f]{40}", commit) is not None


def check_vendoring() -> dict:
    return {
        "safe_vendored_and_pinned": _vendored_and_pinned(
            LIB_SAFE, LIB_SAFE / "contracts" / "GnosisSafe.sol"
        ),
        "baal_vendored_and_pinned": _vendored_and_pinned(
            LIB_BAAL, LIB_BAAL / "contracts" / "Baal.sol"
        ),
    }


# ---------------------------------------------------------------------------
# c2 — wiring
# ---------------------------------------------------------------------------


def check_wiring() -> dict:
    summon_script_present = SUMMON_SCRIPT.is_file()
    governance_baal_after_arm_in_setup = False
    try:
        pkg = json.loads(PACKAGE_JSON.read_text())
        scripts = pkg.get("scripts", {})
        setup = scripts.get("setup", "")
        baal_step = scripts.get("deploy:governance-baal", "")
        baal_step_runs_summon_script = "summon-baal-safe.ts" in baal_step
        governance_idx = setup.find("npm run deploy:governance ")
        baal_idx = setup.find("npm run deploy:governance-baal")
        governance_baal_after_arm_in_setup = (
            baal_step_runs_summon_script
            and governance_idx != -1
            and baal_idx != -1
            and baal_idx > governance_idx
        )
    except (OSError, json.JSONDecodeError):
        pass
    return {
        "summon_script_present": summon_script_present,
        "governance_baal_after_arm_in_setup": governance_baal_after_arm_in_setup,
    }


# ---------------------------------------------------------------------------
# c3/c4/c5 — live fixturenet deploy (safe, shares-token, owner-history)
# ---------------------------------------------------------------------------


def _wait_for_port(port: int, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.5)
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.25)
    raise RuntimeError(f"anvil did not open port {port} within {timeout}s")


def _run_hardhat(script: str, env: dict) -> str:
    result = subprocess.run(
        ["npx", "hardhat", "run", script, "--network", "hub"],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=DEPLOY_TIMEOUT,
    )
    output = result.stdout + result.stderr
    if result.returncode != 0:
        raise RuntimeError(f"{script} failed (exit {result.returncode}):\n{output[-4000:]}")
    return output


def run_deploy_and_get_result() -> dict:
    """Runs a fresh fixturenet deploy (anvil + deploy_governance + summon-baal-safe) on a
    dedicated port, and returns the summon script's DEPLOY_RESULT_JSON payload."""
    env = dict(os.environ)
    env["HUB_RPC"] = HUB_RPC
    anvil = subprocess.Popen(
        ["anvil", "--port", str(ANVIL_PORT), "--chain-id", "31337", "--silent"],
        cwd=REPO_ROOT,
    )
    try:
        _wait_for_port(ANVIL_PORT, ANVIL_READY_TIMEOUT)
        _run_hardhat("scripts/deploy_governance.ts", env)
        summon_output = _run_hardhat("scripts/summon-baal-safe.ts", env)
    finally:
        anvil.terminate()
        try:
            anvil.wait(timeout=10)
        except subprocess.TimeoutExpired:
            anvil.kill()

    m = re.search(r"^DEPLOY_RESULT_JSON=(\{.*\})$", summon_output, re.MULTILINE)
    if not m:
        raise RuntimeError(
            f"summon-baal-safe.ts did not print DEPLOY_RESULT_JSON:\n{summon_output[-4000:]}"
        )
    return json.loads(m.group(1))


def check_safe() -> dict:
    result = run_deploy_and_get_result()
    return {
        "safe_threshold": result["safeThreshold"],
        "safe_owner_count": result["safeOwnerCount"],
        "baal_is_safe_owner": result["baalIsSafeOwner"],
        "human_owner_count": result["safeHumanOwnerCount"],
    }


def check_shares_token() -> dict:
    result = run_deploy_and_get_result()
    return {"shares_token_is_arm": result["sharesTokenIsArm"]}


def check_owner_history() -> dict:
    result = run_deploy_and_get_result()
    history = result["ownerHistory"]
    max_human_owners = max((len(step["humanOwners"]) for step in history), default=0)
    return {
        "max_human_owners_at_any_step": max_human_owners,
        "steps_checked": [step["step"] for step in history],
    }


# ---------------------------------------------------------------------------
# c6 — forge test
# ---------------------------------------------------------------------------


def check_forge_test() -> dict:
    if not FORGE_TEST_PATH.is_file():
        return {"forge_tests_passed": 0, "forge_tests_failed": 1}
    result = subprocess.run(
        ["forge", "test", "--match-path", str(FORGE_TEST_PATH)],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=FORGE_TIMEOUT,
    )
    output = result.stdout + result.stderr
    m = re.search(r"(\d+)\s+tests passed,\s+(\d+)\s+failed", output)
    if not m:
        return {"forge_tests_passed": 0, "forge_tests_failed": 1}
    return {"forge_tests_passed": int(m.group(1)), "forge_tests_failed": int(m.group(2))}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

REPORTS = {
    "vendoring": check_vendoring,
    "wiring": check_wiring,
    "safe": check_safe,
    "shares-token": check_shares_token,
    "owner-history": check_owner_history,
    "forge-test": check_forge_test,
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", choices=sorted(REPORTS.keys()), required=True)
    args = parser.parse_args()
    print(json.dumps(REPORTS[args.report]()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
