#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Locks every real-world project of tests/real-world again with the
# mill-purifier command of this checkout, from the pinned source that
# tests/default.nix builds, and compares the lockfile with the committed
# one. It needs the network. Run it from the repository root after a change
# to the lock run. MILL_PURIFIER_MAVEN_CENTRAL_MIRROR, when it is set, makes
# the lock runs resolve through that mirror; the lockfiles come out the same.
set -euo pipefail

cli=$(nix build --no-link --print-out-paths '.#cli')
system=$(nix eval --raw --impure --expr builtins.currentSystem)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# fansi 0.5.1: the source and the test selector of tests/default.nix.
src=$(nix build --no-link --print-out-paths ".#checks.$system.real-world-fansi-source")
cp -r "$src" "$work/fansi"
chmod -R u+w "$work/fansi"
(
  cd "$work/fansi"
  "$cli/bin/mill-purifier" lock --lockfile "$work/fansi.lock.json" --tests 'fansi.jvm[2.13.15].test.testForked'
)
diff -u tests/real-world/fansi.lock.json "$work/fansi.lock.json"
