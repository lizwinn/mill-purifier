# SPDX-License-Identifier: MIT
"""Ages the version listing of cats-kernel_3 in the lockfile of
tests/fixtures/ranged: it drops every version from 2.10.0 on, as the
listing read before 2.10.0 was published, and seals the lockfile with its
content hash again. `mill-purifier lock` then resolves the range of the
fixture to 2.9.0 and keeps it, which is what the conformance-update check
moves. Make the fixture lockfile from the repository root with

    (cd tests/fixtures/ranged && mill-purifier lock)
    PYTHONPATH=pkgs/cli python3 tests/age-ranged-listing.py
    (cd tests/fixtures/ranged && mill-purifier lock)
"""

import json
import re
from pathlib import Path

import mill_purifier

LOCK = Path("tests/fixtures/ranged") / mill_purifier.LOCK_FILE
LISTING = "/org/typelevel/cats-kernel_3/maven-metadata.xml"


def version_key(version):
    return [int(part) for part in re.findall(r"\d+", version)]


def age(contents):
    versions = re.findall(r"<version>([^<]+)</version>", contents)
    kept = [v for v in versions if version_key(v) < [2, 10, 0]]
    contents = re.sub(r"\s*<version>([^<]+)</version>", lambda m: m.group(0) if m.group(1) in kept else "", contents)
    newest = max(kept, key=version_key)
    contents = re.sub(r"<latest>[^<]*</latest>", f"<latest>{newest}</latest>", contents)
    return re.sub(r"<release>[^<]*</release>", f"<release>{newest}</release>", contents)


lock = json.loads(LOCK.read_text())
aged = 0
for entry in lock["artifacts"]:
    if "contents" in entry and entry["path"].endswith(LISTING):
        entry["contents"] = age(entry["contents"])
        aged += 1
if aged == 0:
    raise SystemExit(f"{LOCK} records no version listing of cats-kernel_3; lock the fixture first")
lock["contentHash"] = mill_purifier.content_hash(lock)
LOCK.write_text(json.dumps(lock, indent=2) + "\n")
