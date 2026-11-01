# Testing

`nix flake check` runs the checks of `tests/default.nix` on the fixture
builds of `tests/fixtures`, from their committed lockfiles, in the Nix
sandbox:

- `cli` builds the mill-purifier command. Its install check runs the unit
  tests of `pkgs/cli/coursier_cache.py` (`test_coursier_cache.py`).
- `simple-*` build `tests/fixtures/simple`, a Scala module with an munit
  suite on the nixpkgs JDK. The package build runs the suite, `simple-run`
  runs the program, `simple-core-jar` reads the jar and the POM, and
  `simple-repository` checks that Mill's Maven publisher, offline,
  publishes the files Nix built.
- `polyglot-*` build `tests/fixtures/polyglot`: Java, Kotlin and Scala
  modules, a dependency from a custom repository (maven.google.com), the
  BuildInfo plugin in the meta-build, a version from git through the git
  shim (tagged and untagged), a module JVM, and Mill's default daemon JVM.
  Its lock holds JDK archives for x86_64-linux, so these checks exist only
  there.
- `treefmt` checks the Nix formatting.

`nix flake check --no-build --all-systems` evaluates the checks of every
system.

The lock run needs the network, so no check runs it. After a change to a
fixture or to the lock run, run `tests/relock-fixtures.sh` from the
repository root and commit the new lockfiles.

Interactive mode and the publish verb are tested by hand, from a fixture:

```zsh
nix run '.#cli' -- mill core.run
MILL_MAVEN_USERNAME=local MILL_MAVEN_PASSWORD=local nix run '.#cli' -- \
  publish mill.javalib.MavenPublishModule/publishAll \
  --releaseUri "file://$PWD/out/repo" --snapshotUri "file://$PWD/out/repo"
```

The first prints `[1,2]` in `tests/fixtures/simple`; in
`tests/fixtures/polyglot`, `hello.run` prints `hello java, kotlin`.

`pkgs/cli/coursier_cache.py` and its tests are shared with the scala-cli
purifier. Keep the two copies identical: make a change in both
repositories.
