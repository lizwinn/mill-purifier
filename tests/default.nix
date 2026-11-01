# SPDX-License-Identifier: MIT
#
# The checks of the flake: the fixture builds of tests/fixtures, made from
# their committed lockfiles in the Nix sandbox, and the mill-purifier
# command (whose install check runs the unit tests of coursier_cache.py).
# `tests/relock-fixtures.sh` writes the lockfiles again.
{
  pkgs,
  overlay,
  cli,
}:
let
  purified = pkgs.extend overlay;
  inherit (purified) lib;
  system = purified.stdenv.hostPlatform.system;

  # The output of a Mill run must equal `expected`.
  prints =
    name: run: expected:
    purified.runCommand name { } ''
      if [ "$(cat ${run})" != ${lib.escapeShellArg expected} ]; then
        echo "${name}: expected ${lib.escapeShellArg expected}, Mill printed:" >&2
        cat ${run} >&2
        exit 1
      fi
      touch $out
    '';

  # Every artifact a package names exists, and the package holds the module
  # at its coordinates in Maven layout.
  hasArtifacts =
    name: package: mavenPath:
    purified.runCommand name { } ''
      test -d ${package}/${mavenPath}
      ${lib.concatMapStrings (file: ''
        test -e ${lib.escapeShellArg file}
      '') (lib.attrValues package.artifacts)}
      touch $out
    '';

  # tests/fixtures/simple: a Scala module with a test suite, on the system
  # JDK.
  simple = purified.buildMillProject {
    src = ./fixtures/simple;
    # Runs the munit suite of core.test in the sandbox.
    doCheck = true;
  };
  core = simple.packages.core;

  # tests/fixtures/polyglot: Java, Kotlin and Scala modules, a custom
  # repository, a meta-build plugin, a version from git, and JVMs Mill
  # downloads. Its lock holds JDK archives for x86_64-linux.
  polyglot = purified.buildMillProject {
    src = ./fixtures/polyglot;
    git = {
      rev = "0123456789abcdef0123456789abcdef01234567";
      revCount = 42;
      tag = "v1.2.3";
      commitsSinceTag = 0;
    };
  };
  # Lockfiles made from the simple fixture with one thing wrong.
  simpleLock = builtins.fromJSON (builtins.readFile ./fixtures/simple/mill-purifier.lock.json);
  lockWith = name: changes: builtins.toFile "${name}.json" (builtins.toJSON (simpleLock // changes));
  simpleWith =
    name: changes:
    purified.buildMillProject {
      src = ./fixtures/simple;
      lockFile = lockWith name changes;
    };
  # A check that evaluating `value` fails, as a lockfile error must.
  failsToEvaluate =
    name: value:
    assert
      !(builtins.tryEval (builtins.seq value true)).success
      || throw "${name}: the evaluation was expected to fail";
    purified.runCommand name { } "touch $out";
  upickleJar = "https/repo1.maven.org/maven2/com/lihaoyi/upickle_3/4.1.0/upickle_3-4.1.0.jar";

  polyglotUntagged = purified.buildMillProject {
    src = ./fixtures/polyglot;
    git = {
      rev = "0123456789abcdef0123456789abcdef01234567";
      revCount = 42;
      tag = "v1.2.3";
      commitsSinceTag = 5;
    };
  };
in
{
  inherit cli;

  simple-core = core;
  simple-core-artifacts = hasArtifacts "simple-core-artifacts" core "example/core_3/0.1.0";
  simple-core-jar =
    purified.runCommand "simple-core-jar" { nativeBuildInputs = [ purified.unzip ]; }
      ''
        unzip -l ${core.artifacts."core_3.jar"} | grep -q 'example/Encode.class'
        grep -q '<artifactId>core_3</artifactId>' ${core.artifacts."core_3.pom"}
        touch $out
      '';
  simple-run = prints "simple-run" (simple.runTask "simple-run-output" [ "core.run" ]) "[1,2]";

  # The Nix side computes the definition hash the command wrote.
  definition-hash =
    assert
      (import ../nix/lib/definition-hash.nix ./fixtures/simple).hash == simpleLock.definitionHash
      || throw "definition-hash: nix/lib/definition-hash.nix disagrees with mill_purifier.definition_hash";
    purified.runCommand "definition-hash" { } "touch $out";

  # A stale lock, a lockfile without the fields of a lock, and a lockfile
  # of another format version stop the build at evaluation.
  stale-lock =
    failsToEvaluate "stale-lock"
      (simpleWith "stale" {
        definitionHash = "sha256:0";
      }).packages.core.drvPath;
  malformed-lock =
    failsToEvaluate "malformed-lock"
      (purified.buildMillProject {
        src = ./fixtures/simple;
        lockFile = builtins.toFile "malformed.json" ''{"version": 1}'';
        checkLock = false;
      }).packages;
  other-format-version =
    failsToEvaluate "other-format-version"
      (simpleWith "version" {
        version = 99;
      }).packages;

  # A lock that lacks a download fails in the sandbox, offline, and the
  # build says which command fixes it.
  missing-download =
    purified.runCommand "missing-download"
      {
        failed =
          purified.testers.testBuildFailure
            (simpleWith "missing" {
              artifacts = builtins.filter (a: a.path != upickleJar) simpleLock.artifacts;
            }).packages.core;
      }
      ''
        grep -F 'run `mill-purifier lock`' $failed/testBuildFailure.log
        touch $out
      '';

  # Mill's Maven publisher, offline, publishes the files Nix built.
  simple-repository = purified.runCommand "simple-repository" { } ''
    cmp ${simple.repository}/example/core_3/0.1.0/core_3-0.1.0.jar ${core.artifacts."core_3.jar"}
    cmp ${simple.repository}/example/core_3/0.1.0/core_3-0.1.0.pom ${core.artifacts."core_3.pom"}
    test -f ${simple.repository}/example/core_3/0.1.0/core_3-0.1.0-sources.jar.sha1
    touch $out
  '';
}
// lib.optionalAttrs (polyglot.lock.platforms ? ${system}) {
  polyglot-greeter-package = polyglot.packages.greeter;
  polyglot-hello-package = polyglot.packages.hello;
  polyglot-versioned-package = polyglot.packages.versioned;
  polyglot-greeter =
    hasArtifacts "polyglot-greeter" polyglot.packages.greeter
      "example/greeter/0.1.0";
  polyglot-hello = hasArtifacts "polyglot-hello" polyglot.packages.hello "example/hello/0.1.0";
  # The version comes from the git shim: the tag, without its `v`.
  polyglot-versioned =
    hasArtifacts "polyglot-versioned" polyglot.packages.versioned
      "example/versioned_3/1.2.3";
  # After the tag: <tag>-<commits>-<six digits of the commit>.
  polyglot-versioned-untagged =
    hasArtifacts "polyglot-versioned-untagged" polyglotUntagged.packages.versioned
      "example/versioned_3/1.2.3-5-012345";
  polyglot-hello-run = prints "polyglot-hello-run" (polyglot.runTask "polyglot-hello-output" [
    "hello.run"
  ]) "hello java, kotlin";
  polyglot-versioned-run = prints "polyglot-versioned-run" (polyglot.runTask
    "polyglot-versioned-output"
    [ "versioned.run" ]
  ) "built with Scala 3.7.3";
  polyglot-repository = purified.runCommand "polyglot-repository" { } ''
    for path in example/greeter/0.1.0/greeter-0.1.0.jar example/hello/0.1.0/hello-0.1.0.jar example/versioned_3/1.2.3/versioned_3-1.2.3.jar; do
      test -f ${polyglot.repository}/$path
    done
    touch $out
  '';
}
