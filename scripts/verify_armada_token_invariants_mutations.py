#!/usr/bin/env python3
"""
ABOUTME: Verifies the ArmadaToken invariant checker (scripts/check-armada-token-invariants.py)
ABOUTME: still imports without error and that every remaining mutation in its
ABOUTME: MUTATIONS registry still applies to the live contracts/governance/ArmadaToken.sol.

Usage:
  python3 scripts/verify_armada_token_invariants_mutations.py --apply-all
"""
import argparse
import importlib
import importlib.util
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TOKEN_PATH = REPO_ROOT / "contracts" / "governance" / "ArmadaToken.sol"
CHECKER_PATH = Path(__file__).resolve().parent / "check-armada-token-invariants.py"


def _load_checker():
    """Import the checker module by file path (its filename has dashes)."""
    if not CHECKER_PATH.exists():
        return None
    spec = importlib.util.spec_from_file_location(
        "check_armada_token_invariants", str(CHECKER_PATH)
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply-all", action="store_true",
                        help="Import the checker and apply every remaining mutation to the token source.")
    args = parser.parse_args()

    checker = _load_checker()
    import_ok = checker is not None

    mutations_total = 0
    mutations_failed = 0
    if args.apply_all and checker is not None:
        token_src = TOKEN_PATH.read_text()
        for name, fn in checker.MUTATIONS.items():
            mutations_total += 1
            try:
                fn(token_src)
            except Exception:
                mutations_failed += 1

    result = {
        "import_ok": import_ok,
        "mutations_total": mutations_total,
        "mutations_failed": mutations_failed,
        "mutations_passed": mutations_total - mutations_failed,
    }
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
