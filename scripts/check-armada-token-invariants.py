#!/usr/bin/env python3
"""
ABOUTME: Verifies the six ArmadaToken Baal-shares invariants are enforced by
ABOUTME: test-foundry/ArmadaTokenShares.t.sol: for each, confirms the test
ABOUTME: exists and passes on the real contract, then applies the matching
ABOUTME: breaking mutation and confirms the test fails. See
ABOUTME: docs/tasks/G1-arm-shares-token.md and
ABOUTME: labbook/2026-10-18-treasury-governance-baal-safe-shielded.md §3-4.

Usage:
  check-armada-token-invariants.py --assertion <name> --mutate <mutation>
  check-armada-token-invariants.py --all
  check-armada-token-invariants.py --regression
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TOKEN_PATH = REPO_ROOT / "contracts" / "governance" / "ArmadaToken.sol"
TEST_PATH = REPO_ROOT / "test-foundry" / "ArmadaTokenShares.t.sol"
TEST_CONTRACT = "ArmadaTokenSharesTest"

FORGE_TIMEOUT = 300

# ---------------------------------------------------------------------------
# Assertion -> (forge test function, breaking mutation) registry.
# ---------------------------------------------------------------------------

ASSERTIONS = {
    "single-mint": {
        "test": "test_shares_singleMint",
        "mutation": "second-mint",
    },
    "non-proxy-bytecode": {
        "test": "test_shares_nonProxyBytecode",
        "mutation": "proxy",
    },
    "whitelist-gating": {
        "test": "test_shares_whitelistGating",
        "mutation": "open-add-to-whitelist",
    },
    "restricted-transfer-reverts": {
        "test": "test_shares_restrictedTransferReverts",
        "mutation": "allow-non-whitelisted-transfer",
    },
    "mint-not-blocked": {
        "test": "test_shares_mintNotBlocked",
        "mutation": "block-mint",
    },
    "timelock-set-transferable": {
        "test": "test_shares_timelockSetTransferable",
        "mutation": "require-wind-down-contract",
    },
}

# ---------------------------------------------------------------------------
# Mutations: each is (anchor_text, replacement_text). The anchor must appear
# exactly once in the live source; mutation is applied by substring
# replacement and reverted by restoring the exact original text.
# ---------------------------------------------------------------------------


def _mutation_second_mint(src: str) -> str:
    anchor = (
        "        timelock = _timelock;\n"
        "        tokenDeployer = msg.sender;\n"
        "        _mint(initialHolder, INITIAL_SUPPLY);\n"
        "    }\n"
    )
    assert src.count(anchor) == 1, "second-mint anchor not found exactly once"
    replacement = anchor + (
        "\n"
        "    // MUTATION(second-mint): a second _mint call site, for mutation-kill testing.\n"
        "    function _TEST_MUTATION_secondMint(address to, uint256 amount) external {\n"
        "        _mint(to, amount);\n"
        "    }\n"
    )
    return src.replace(anchor, replacement, 1)


def _mutation_proxy(src: str) -> str:
    anchor = (
        "        timelock = _timelock;\n"
        "        tokenDeployer = msg.sender;\n"
        "        _mint(initialHolder, INITIAL_SUPPLY);\n"
        "    }\n"
    )
    assert src.count(anchor) == 1, "proxy anchor not found exactly once"
    replacement = anchor + (
        "\n"
        "    // MUTATION(proxy): introduces a delegatecall path, for mutation-kill testing.\n"
        "    function _TEST_MUTATION_proxyCall(address impl, bytes calldata data) external returns (bytes memory) {\n"
        "        (bool ok, bytes memory ret) = impl.delegatecall(data);\n"
        "        require(ok, \"delegatecall failed\");\n"
        "        return ret;\n"
        "    }\n"
    )
    return src.replace(anchor, replacement, 1)


def _mutation_open_add_to_whitelist(src: str) -> str:
    anchor = (
        "    function addToWhitelist(address account) external {\n"
        "        require(msg.sender == timelock, \"ArmadaToken: not timelock\");\n"
        "        require(account != address(0), \"ArmadaToken: zero address\");\n"
    )
    assert src.count(anchor) == 1, "open-add-to-whitelist anchor not found exactly once"
    replacement = (
        "    function addToWhitelist(address account) external {\n"
        "        require(account != address(0), \"ArmadaToken: zero address\");\n"
    )
    return src.replace(anchor, replacement, 1)


def _mutation_allow_non_whitelisted_transfer(src: str) -> str:
    anchor = (
        "        if (!transferable) {\n"
        "            require(from == address(0) || transferWhitelist[from], \"ArmadaToken: transfers restricted\");\n"
        "        }\n"
    )
    assert src.count(anchor) == 1, "allow-non-whitelisted-transfer anchor not found exactly once"
    replacement = (
        "        if (!transferable) {\n"
        "            require(true, \"ArmadaToken: transfers restricted\");\n"
        "        }\n"
    )
    return src.replace(anchor, replacement, 1)


def _mutation_block_mint(src: str) -> str:
    anchor = (
        "        if (!transferable) {\n"
        "            require(from == address(0) || transferWhitelist[from], \"ArmadaToken: transfers restricted\");\n"
        "        }\n"
    )
    assert src.count(anchor) == 1, "block-mint anchor not found exactly once"
    replacement = (
        "        if (!transferable) {\n"
        "            require(transferWhitelist[from], \"ArmadaToken: transfers restricted\");\n"
        "        }\n"
    )
    return src.replace(anchor, replacement, 1)


def _mutation_require_wind_down_contract(src: str) -> str:
    anchor = (
        "    function setTransferable(bool _transferable) external {\n"
        "        require(msg.sender == windDownContract || msg.sender == timelock, \"ArmadaToken: not authorized\");\n"
    )
    assert src.count(anchor) == 1, "require-wind-down-contract anchor not found exactly once"
    replacement = (
        "    function setTransferable(bool _transferable) external {\n"
        "        require(windDownContract != address(0), \"ArmadaToken: wind-down not set\");\n"
        "        require(msg.sender == windDownContract || msg.sender == timelock, \"ArmadaToken: not authorized\");\n"
    )
    return src.replace(anchor, replacement, 1)


MUTATIONS = {
    "second-mint": _mutation_second_mint,
    "proxy": _mutation_proxy,
    "open-add-to-whitelist": _mutation_open_add_to_whitelist,
    "allow-non-whitelisted-transfer": _mutation_allow_non_whitelisted_transfer,
    "block-mint": _mutation_block_mint,
    "require-wind-down-contract": _mutation_require_wind_down_contract,
}


# ---------------------------------------------------------------------------
# Forge helpers.
# ---------------------------------------------------------------------------


def run_forge_test(test_name: str) -> tuple:
    """Runs a single forge test function. Returns (passed, raw_output)."""
    result = subprocess.run(
        [
            "forge",
            "test",
            "--match-contract",
            TEST_CONTRACT,
            "--match-test",
            f"^{re.escape(test_name)}\\(\\)$",
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=FORGE_TIMEOUT,
    )
    output = result.stdout + result.stderr
    pass_marker = re.search(rf"\[PASS\]\s+{re.escape(test_name)}\(", output)
    fail_marker = re.search(rf"\[FAIL[^\]]*\]\s+{re.escape(test_name)}\(", output)
    if pass_marker and not fail_marker:
        return True, output
    if fail_marker:
        return False, output
    # Compiler error or no matching test at all (e.g. a mutation that breaks
    # compilation, or a renamed/missing test): treat as a failure to find the
    # invariant enforced.
    return False, output


def read_token_source() -> str:
    return TOKEN_PATH.read_text()


def write_token_source(text: str) -> None:
    TOKEN_PATH.write_text(text)


def with_mutation(mutation_name: str, fn):
    """Applies `mutation_name`, runs `fn()`, restores the original source."""
    original = read_token_source()
    try:
        mutated = MUTATIONS[mutation_name](original)
        write_token_source(mutated)
        # Confirm the write landed (the mutation actually reached the file on
        # disk), not merely that the in-memory string differs.
        on_disk = read_token_source()
        if on_disk != mutated:
            raise RuntimeError(f"mutation {mutation_name} did not take effect on disk")
        return fn()
    finally:
        write_token_source(original)


# ---------------------------------------------------------------------------
# Per-assertion check.
# ---------------------------------------------------------------------------


def check_assertion(assertion_name: str, mutation_name: str) -> dict:
    spec = ASSERTIONS.get(assertion_name)
    if spec is None:
        return {"present": False, "passes_unmutated": False, "fails_under_mutation": False}
    test_name = spec["test"]

    # Does the test exist in the committed test file at all?
    test_source = TEST_PATH.read_text() if TEST_PATH.exists() else ""
    exists_in_source = re.search(rf"function\s+{re.escape(test_name)}\s*\(", test_source) is not None

    passed_unmutated, _ = run_forge_test(test_name)
    present = exists_in_source and passed_unmutated

    if mutation_name not in MUTATIONS:
        raise ValueError(f"unknown mutation: {mutation_name}")

    def _run():
        return run_forge_test(test_name)

    passed_mutated, _ = with_mutation(mutation_name, _run)
    fails_under_mutation = not passed_mutated

    return {
        "present": present,
        "passes_unmutated": passed_unmutated,
        "fails_under_mutation": fails_under_mutation,
    }


# ---------------------------------------------------------------------------
# --all: run every assertion/mutation pair, aggregate.
# ---------------------------------------------------------------------------


def check_all() -> dict:
    assertions_missing = 0
    mutations_surviving = 0
    details = {}
    for name, spec in ASSERTIONS.items():
        result = check_assertion(name, spec["mutation"])
        details[name] = result
        if not result["present"]:
            assertions_missing += 1
        if not result["fails_under_mutation"]:
            mutations_surviving += 1
    return {
        "assertions_missing": assertions_missing,
        "mutations_surviving": mutations_surviving,
        "details": details,
    }


# ---------------------------------------------------------------------------
# --regression: full existing suite passes; no windDownContract set by this
# chunk's deliverables; protected functions untouched.
# ---------------------------------------------------------------------------

PROTECTED_FUNCTIONS = [
    "delegateOnBehalf",
    "transferAndDelegate",
    "circulatingSupplyOf",
    "_delegate",
]

# Reference bodies captured from the known-good ArmadaToken.sol (the file
# this chunk must not edit). Whitespace-normalized before comparison so
# incidental reformatting elsewhere in the file does not false-positive.
PROTECTED_REFERENCE = {
    "delegateOnBehalf": """function delegateOnBehalf(address delegator, address delegatee) external {
        require(authorizedDelegator[msg.sender], "ArmadaToken: not authorized delegator");
        _delegate(delegator, delegatee);
    }""",
    "transferAndDelegate": """function transferAndDelegate(address to, uint256 amount, address delegatee) external {
        require(authorizedDelegator[msg.sender], "ArmadaToken: not authorized delegator");
        _transfer(msg.sender, to, amount);
        _delegate(to, delegatee);
    }""",
    "circulatingSupplyOf": """function circulatingSupplyOf(address[] calldata excluded) external view returns (uint256 result) {
        result = totalSupply();
        for (uint256 i; i < excluded.length; i++) {
            result -= balanceOf(excluded[i]);
        }
    }""",
    "_delegate": """function _delegate(address delegator, address delegatee) internal override {
        require(!noDelegation[delegator], "ArmadaToken: delegation blocked");
        super._delegate(delegator, delegatee);
    }""",
}


def _normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def _extract_function(src: str, name: str) -> str:
    """Extracts `function <name>(...) {...}` by brace counting, starting at
    the first `function <name>(` match."""
    m = re.search(rf"function\s+{re.escape(name)}\s*\(", src)
    if not m:
        return ""
    start = m.start()
    brace_start = src.index("{", m.end())
    depth = 0
    i = brace_start
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[start : i + 1]
        i += 1
    return ""


def count_protected_functions_changed() -> int:
    src = read_token_source()
    changed = 0
    for name in PROTECTED_FUNCTIONS:
        live = _normalize(_extract_function(src, name))
        expected = _normalize(PROTECTED_REFERENCE[name])
        if live != expected:
            changed += 1
    return changed


def count_wind_down_contract_set() -> int:
    """Scopes the check to this chunk's own deliverables: the new test file
    and this checker script. Pre-existing tests/deploy scripts for the
    (still-present, soon-to-be-removed-in-G6) wind-down contract call
    setWindDownContract legitimately and are out of this chunk's scope."""
    count = 0
    for path in (TEST_PATH, Path(__file__).resolve()):
        if path.exists():
            count += len(re.findall(r"setWindDownContract\s*\(", path.read_text()))
    return count


def run_full_forge_suite() -> int:
    """Runs the entire forge suite; returns the number of failed tests."""
    result = subprocess.run(
        ["forge", "test"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=1800,
    )
    output = result.stdout + result.stderr
    # Forge prints a final summary line like:
    # "Ran 73 test suites in 61.92s (255.98s CPU time): 794 tests passed, 0 failed, 0 skipped (794 total tests)"
    m = re.search(r"(\d+)\s+tests passed,\s+(\d+)\s+failed", output)
    if not m:
        # No summary line found at all (e.g. a compile error): treat as a
        # total failure of the suite.
        return 1
    return int(m.group(2))


def check_regression() -> dict:
    existing_suite_failures = run_full_forge_suite()
    wind_down_contract_set_count = count_wind_down_contract_set()
    protected_functions_changed = count_protected_functions_changed()
    return {
        "existing_suite_failures": existing_suite_failures,
        "wind_down_contract_set_count": wind_down_contract_set_count,
        "protected_functions_changed": protected_functions_changed,
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assertion", choices=sorted(ASSERTIONS.keys()))
    parser.add_argument("--mutate", choices=sorted(MUTATIONS.keys()))
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--regression", action="store_true")
    args = parser.parse_args()

    if args.all:
        print(json.dumps(check_all()))
        return 0

    if args.regression:
        print(json.dumps(check_regression()))
        return 0

    if args.assertion and args.mutate:
        result = check_assertion(args.assertion, args.mutate)
        print(json.dumps(result))
        return 0

    parser.error("must pass --assertion/--mutate, --all, or --regression")
    return 2


if __name__ == "__main__":
    sys.exit(main())
