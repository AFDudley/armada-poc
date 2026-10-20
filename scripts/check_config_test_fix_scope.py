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

TARGET = "config/networks.test.ts"

# The grader rebases the branch onto the current integration tip before it runs this probe,
# so a hardcoded base sha would include every commit merged since the branch was cut. Derive
# the base at run time as the merge-base with the integration branch (the rebase target); the
# tightest (newest) merge-base among the candidate refs is that target.
CANDIDATE_REFS = ("main", "integrated", "origin/main", "origin/integrated")

# Exclude the bus, the exophial control dir, the engine-derived spec, and this task's own
# acceptance probes (declared_new_entrypoints) — none of them are production or test code.
EXCLUDE_PREFIXES = (".pebbles/", ".exophial/", "contracts/specs/")
EXCLUDE_EXACT = {
    "scripts/check_test_config_run.py",
    "scripts/check_config_test_fix_scope.py",
}


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args], cwd=REPO_ROOT, capture_output=True, text=True
    )


def find_base() -> str | None:
    best_base: str | None = None
    best_distance: int | None = None
    for ref in CANDIDATE_REFS:
        if git("rev-parse", "--verify", "--quiet", ref).returncode != 0:
            continue
        merge_base = git("merge-base", "HEAD", ref)
        base = merge_base.stdout.strip()
        if merge_base.returncode != 0 or not base:
            continue
        count = git("rev-list", "--count", f"{base}..HEAD")
        if count.returncode != 0 or not count.stdout.strip():
            continue
        distance = int(count.stdout.strip())
        if best_distance is None or distance < best_distance:
            best_base, best_distance = base, distance
    return best_base


def is_infrastructure(path: str) -> bool:
    return path.startswith(EXCLUDE_PREFIXES) or path in EXCLUDE_EXACT


def main() -> int:
    base = find_base()
    if base is None:
        # No integration ref present: fall back to the branch's recorded base.
        base = "13835aa20fba55dce6586f60876557aab8a041f1"

    diff = git("diff", "--name-only", base, "HEAD")
    changed = [
        line.strip()
        for line in diff.stdout.splitlines()
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
