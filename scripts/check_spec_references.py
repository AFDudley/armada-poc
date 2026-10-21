#!/usr/bin/env python3
# ABOUTME: Checks that exactly one GOVERNANCE.md and one ARM_TOKEN.md are tracked in the tree, and
# ABOUTME: that every PATH-LIKE reference to them resolves to a tracked file. A path-like reference
# ABOUTME: is a path that carries a directory separator (a leading dir, e.g. the specs directory) or a
# ABOUTME: markdown link target. A bare filename in prose ("see GOVERNANCE.md") is not a path
# ABOUTME: reference and is not checked. Emits JSON {governance_files, arm_token_files,
# ABOUTME: dangling_references, dangling}. Exit 0 when one file of each kind exists and nothing
# ABOUTME: dangles. Supports arp-ef0 (one canonical spec of each kind).
import json
import os
import re
import subprocess
import sys


def tracked_files():
    out = subprocess.run(
        ["git", "ls-files"], capture_output=True, text=True, check=True
    ).stdout
    return [line for line in out.splitlines() if line]


FILES = tracked_files()
TRACKED = set(FILES)


def count_tracked(name):
    pat = re.compile(r"(^|/)" + re.escape(name) + r"$")
    return [f for f in FILES if pat.search(f)]


# A path-like reference: a token that contains a directory separator and ends in GOVERNANCE.md or
# ARM_TOKEN.md, or a markdown link target ending in one of them.
PATHREF = re.compile(
    r"[\w.\-]*/[\w./\-]*?(?:GOVERNANCE|ARM_TOKEN)\.md"
    r"|\]\(\s*([^)\s]*(?:GOVERNANCE|ARM_TOKEN)\.md)\s*\)"
)

gov_files = count_tracked("GOVERNANCE.md")
arm_files = count_tracked("ARM_TOKEN.md")

dangling = []
for f in FILES:
    try:
        with open(f, "r", encoding="utf-8") as fh:
            text = fh.read()
    except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError, PermissionError):
        continue
    for m in PATHREF.finditer(text):
        ref = (m.group(1) or m.group(0) or "").strip()
        if ref.startswith("]("):
            ref = ref[2:].strip().rstrip(")").strip()
        if not ref:
            continue
        norm = os.path.normpath(ref)
        if norm not in TRACKED:
            dangling.append({"file": f, "reference": ref})

result = {
    "governance_files": len(gov_files),
    "arm_token_files": len(arm_files),
    "dangling_references": len(dangling),
    "dangling": dangling,
}
print(json.dumps(result))
ok = len(gov_files) == 1 and len(arm_files) == 1 and len(dangling) == 0
sys.exit(0 if ok else 1)
