#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Writes the lockfile of every fixture build again, with the mill-purifier
# command of this checkout. It needs the network. Run it from the
# repository root after a change to a fixture or to the lock run.
set -euo pipefail

cli=$(nix build --no-link --print-out-paths '.#cli')
for fixture in tests/fixtures/*/; do
  echo "relocking $fixture" >&2
  (cd "$fixture" && "$cli/bin/mill-purifier" relock)
done
