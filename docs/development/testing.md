# Testing

`nix flake check` runs the checks of `tests/default.nix`, on x86_64-linux
and aarch64-linux, from the committed lockfiles of `tests/fixtures`, in the
Nix sandbox:

- `cli` builds the mill-purifier command. Its install check runs the unit
  tests of `pkgs/cli`: `test_coursier_cache.py` (shared with the scala-cli
  purifier) and `test_mill_purifier.py` (the parsing of the build, the
  definition and content hashes, artifact names, the JVM index and the
  platform part of the lock, the mirror, the lockfile errors, the prefetch
  record, the resolution-failure hint, the BSP client).
- `simple-*` build `tests/fixtures/simple`, a Scala module with an munit
  suite on the nixpkgs JDK: the package, its test run (`simple-tests`), its
  program (`simple-run`), its jar and POM, and its release, which Mill's
  Maven publisher publishes offline from the files Nix built.
- `polyglot-*` build `tests/fixtures/polyglot`: Java, Kotlin and Scala
  modules, a dependency from a custom repository (maven.google.com), the
  BuildInfo plugin in the meta-build, a version from git through the git
  shim (tagged and untagged), a module JVM, and Mill's default daemon JVM.
- `definition-hash` checks that the Nix side computes the definition hash
  the command wrote.
- `publisher-available` checks which Mill versions have the Maven
  publisher: 1.1.0 and later do, the 1.0 releases and 1.1.0-RC1 do not.
- `real-world-fansi-*` build fansi 0.5.1 from `tests/real-world/fansi.lock.json`:
  its JVM tests (`real-world-fansi-tests`), all nine packages
  (`real-world-fansi-packages`), the version from the git shim
  (`real-world-fansi-version`), and the message of `release` on Mill 1.0.0
  (`real-world-fansi-release`). `real-world-fansi-source` is the pinned
  source tree, which `tests/relock-real-world.sh` uses.
- The conformance checks of the purifier contract that run in the sandbox:
  `conformance-stale`, `conformance-tampered`, `conformance-malformed`,
  `conformance-other-version`, `conformance-missing`,
  `conformance-external` (a source tree without its lockfile, built from
  one kept outside it) and `conformance-offline` (the everyday loop through
  `mill-purifier mill` after a prefetch, with no network).
- `treefmt` checks the Nix formatting.

Four checks need what the sandbox does not have, so they are jobs in
`.github/workflows/check.yml`, on both architectures:

- `conformance-relock-real-world` runs `tests/relock-real-world.sh`, which
  locks fansi again from its pinned source and compares the lockfile with
  the committed one.
- `conformance-relock` runs `tests/relock-fixtures.sh`, which locks every
  fixture again with the network, and fails when a lockfile changed. For
  `tests/fixtures/ranged`, whose dependency has a version range, this
  checks that `lock` keeps the resolution of the lockfile.
- `conformance-update` runs `tests/update-fixture.sh`, which runs
  `mill-purifier update` on a copy of `tests/fixtures/ranged` and checks
  that cats-kernel moves from 2.9.0 to 2.10.0 and that `readLock` then
  reports no problem. The fixture lockfile pins 2.9.0 because it records
  the version listing as it was before 2.10.0;
  `tests/age-ranged-listing.py` describes how it is made.
- `conformance-rebuild` builds the fixture packages twice
  (`nix build --rebuild`) and fails when the outputs differ.

After a change to a fixture or to the lock run, run
`tests/relock-fixtures.sh` and `tests/relock-real-world.sh` from the
repository root and commit the new lockfiles. The second script prints the
difference to the committed lockfile and leaves it unchanged: copy the
lockfile it wrote into `tests/real-world`, or lock with `--lockfile`. When Maven Central rate-limits the machine, set
`MILL_PURIFIER_MAVEN_CENTRAL_MIRROR` (see the README).

`pkgs/cli/coursier_cache.py` and its tests are shared with the scala-cli
purifier. Keep the two copies identical: make a change in both
repositories.
