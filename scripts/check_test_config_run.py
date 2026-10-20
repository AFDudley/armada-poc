#!/usr/bin/env python3
# ABOUTME: Acceptance oracle for arp-d0f clause c1. Runs `npm run test:config` and emits
# ABOUTME: one JSON object on stdout: whether the ESM run completed with no "__dirname is
# ABOUTME: not defined" ReferenceError and how many networks config tests executed.
# ABOUTME: See contracts/specs/derived-arp-d0f.spec.json.
import json
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main() -> int:
    proc = subprocess.run(
        ["npm", "run", "test:config"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    output = proc.stdout + proc.stderr

    # Under ESM an undefined __dirname raises "__dirname is not defined"; count every one.
    dirname_reference_error_count = output.count("__dirname is not defined")

    # Mocha prints a summary like "82 passing" / "66 failing"; executed = passing + failing.
    passing = sum(int(m) for m in re.findall(r"(\d+) passing", output))
    failing = sum(int(m) for m in re.findall(r"(\d+) failing", output))
    networks_tests_executed = passing + failing

    # The run completed under ESM if mocha reached its summary (any executed test). A crash
    # on __dirname (or any top-level ReferenceError) stops before the summary, so there is
    # no "passing"/"failing" line and this is false.
    run_completed = networks_tests_executed > 0

    print(
        json.dumps(
            {
                "dirname_reference_error_count": dirname_reference_error_count,
                "networks_tests_executed": networks_tests_executed,
                "run_completed": run_completed,
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
