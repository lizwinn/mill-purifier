#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Writes the lockfile of every fixture build again, with the mill-purifier
# command of this checkout. It needs the network. Run it from the
# repository root after a change to a fixture or to the lock run.
# MILL_PURIFIER_MAVEN_CENTRAL_MIRROR, when it is set, makes the lock runs
# resolve through that mirror; the lockfiles come out the same.
set -euo pipefail

cli=$(nix build --no-link --print-out-paths '.#cli')
for fixture in tests/fixtures/*/; do
  echo "locking $fixture" >&2
  (cd "$fixture" && "$cli/bin/mill-purifier" lock)
done
