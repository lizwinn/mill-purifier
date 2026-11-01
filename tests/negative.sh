#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Negative tests that need a Nix installation outside the sandbox, so
# `nix flake check` cannot run them: a lockfile whose hash for a download
# was edited makes the mill-purifier command stop, with Nix's hash mismatch
# and the command to run. Run it from the repository root.
set -euo pipefail

cli=$(nix build --no-link --print-out-paths '.#cli')
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r tests/fixtures/simple/. "$work/"
rm -rf "$work/out"

# Replace the hash of the upickle jar with a hash no file has.
python3 - "$work/mill-purifier.lock.json" <<'EOF'
import json, sys
path = sys.argv[1]
lock = json.load(open(path))
for entry in lock["artifacts"]:
    if entry.get("path", "").endswith("/upickle_3-4.1.0.jar"):
        entry["hash"] = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
json.dump(lock, open(path, "w"), indent=2)
EOF

if (cd "$work" && XDG_CACHE_HOME="$work/cache" "$cli/bin/mill-purifier" mill version) >"$work/log" 2>&1; then
  echo "negative.sh: a tampered hash did not stop mill-purifier" >&2
  exit 1
fi
grep -q 'hash mismatch' "$work/log"
grep -q 'run `mill-purifier relock`' "$work/log"
echo "negative.sh: a tampered hash stops mill-purifier with the command to run"
