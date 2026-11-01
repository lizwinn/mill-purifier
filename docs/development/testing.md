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
- The conformance checks of the purifier contract that run in the sandbox:
  `conformance-stale`, `conformance-tampered`, `conformance-malformed`,
  `conformance-other-version`, `conformance-missing`,
  `conformance-external` (a source tree without its lockfile, built from
  one kept outside it) and `conformance-offline` (the everyday loop through
  `mill-purifier mill` after a prefetch, with no network).
- `treefmt` checks the Nix formatting.

Two conformance checks need what the sandbox does not have, so they are
jobs of the same name in `.github/workflows/check.yml`, on both
architectures:

- `conformance-relock` runs `tests/relock-fixtures.sh`, which locks every
  fixture again with the network, and fails when a lockfile changed.
- `conformance-rebuild` builds the fixture packages twice
  (`nix build --rebuild`) and fails when the outputs differ.

After a change to a fixture or to the lock run, run
`tests/relock-fixtures.sh` from the repository root and commit the new
lockfiles. When Maven Central rate-limits the machine, set
`MILL_PURIFIER_MAVEN_CENTRAL_MIRROR` (see the README).

`pkgs/cli/coursier_cache.py` and its tests are shared with the scala-cli
purifier. Keep the two copies identical: make a change in both
repositories.
