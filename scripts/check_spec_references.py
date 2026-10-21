#!/usr/bin/env python3
# ABOUTME: Acceptance-oracle reference check for arp-ef0 (deduplicate governance + ARM token
# ABOUTME: specs). The tree carries exactly one GOVERNANCE.md and one ARM_TOKEN.md (both
# ABOUTME: under specs/), and every tracked reference to them resolves to a path that exists.
import json
import os
import re
import subprocess

FIXED_FILES = [
    "config/mainnet.env",
    "config/networks.ts",
    "config/networks.test.ts",
    "scripts/check-governance-deploy.sh",
    "scripts/deploy_crowdfund.ts",
]
NAME_RE = re.compile(r'GOVERNANCE\.md|ARM_TOKEN\.md')


def repo_root():
    return subprocess.check_output(["git", "rev-parse", "--toplevel"], text=True).strip()


def tracked():
    return subprocess.check_output(["git", "ls-files"], text=True).splitlines()


def main():
    root = repo_root()

    # c1: exactly one spec file of each kind is tracked.
    governance_files = sum(1 for f in tracked() if re.search(r'(^|/)GOVERNANCE\.md$', f))
    arm_token_files = sum(1 for f in tracked() if re.search(r'(^|/)ARM_TOKEN\.md$', f))

    # c2: every tracked reference in the reference set points to a path that exists.
    refs = set(FIXED_FILES)
    for f in tracked():
        if f.startswith("docs/") or (
            f.startswith("specs/") and f.count("/") == 1 and f.endswith(".md")
        ):
            refs.add(f)

    dangling = 0
    for f in sorted(refs):
        path = os.path.join(root, f)
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                for m in NAME_RE.finditer(line):
                    name = m.group(0)
                    start = m.start()
                    prev = line[max(0, start - 30):start]
                    if "specs/" in prev:
                        target = "specs/" + name
                    else:
                        target = name
                    if not os.path.exists(os.path.join(root, target)):
                        dangling += 1

    print(json.dumps({
        "governance_files": governance_files,
        "arm_token_files": arm_token_files,
        "dangling_references": dangling,
    }))
    return 0 if (governance_files == 1 and arm_token_files == 1 and dangling == 0) else 1


if __name__ == "__main__":
    raise SystemExit(main())
