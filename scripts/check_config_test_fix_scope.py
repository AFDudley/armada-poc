#!/usr/bin/env python3
# ABOUTME: Acceptance oracle for arp-d0f clause c3. Emits one JSON object on stdout: whether
# ABOUTME: config/networks.test.ts changed versus the branch base, and how many OTHER files
# ABOUTME: changed (the fix must touch no config loader and no other test).
# ABOUTME: See contracts/specs/derived-arp-d0f.spec.json.
import json
import os
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The commit arp-d0f branched from. Anything that already differed at this point is
# pre-existing, not introduced by this task.
BASE_SHA = "13835aa20fba55dce6586f60876557aab8a041f1"

TARGET = "config/networks.test.ts"

# Exclude the bus, the exophial control dir, the engine-derived spec, and this task's own
# acceptance probes (declared_new_entrypoints) — none of them are production or test code.
EXCLUDE_PREFIXES = (".pebbles/", ".exophial/", "contracts/specs/")
EXCLUDE_EXACT = {
    "scripts/check_test_config_run.py",
    "scripts/check_config_test_fix_scope.py",
}


def is_infrastructure(path: str) -> bool:
    return path.startswith(EXCLUDE_PREFIXES) or path in EXCLUDE_EXACT


def main() -> int:
    proc = subprocess.run(
        ["git", "diff", "--name-only", BASE_SHA, "HEAD"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    changed = [
        line.strip()
        for line in proc.stdout.splitlines()
        if line.strip() and not is_infrastructure(line.strip())
    ]

    outside = [path for path in changed if path != TARGET]

    print(
        json.dumps(
            {
                "changed_files_outside_networks_test": len(outside),
                "networks_test_changed": TARGET in changed,
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
