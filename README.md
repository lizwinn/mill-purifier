# mill-purifier

A command and a Nix library that build a [Mill](https://mill-build.org)
project in the Nix sandbox. Mill still plans the build. `mill-purifier lock`
records every file the build downloads in a lockfile, together with the
modules the build publishes, and Nix builds the project from that lockfile,
offline, without generated Nix files in the repository. mill-purifier is
part of [nix-purifiers](https://nix-purifiers.github.io) and meets its
[purifier contract](https://github.com/nix-purifiers/purifier/blob/main/CONTRACT.md).
It supports Mill 1.x, and Java, Kotlin and Scala modules.

## Quickstart

Lock the build from its root and commit `mill-purifier.lock.json`:

```zsh
nix run github:nix-purifiers/mill-purifier -- lock
```

The build must pin its Mill version, in the `//| mill-version:` header of
`build.mill` or in `.mill-version`.

Build it with Nix. The flake publishes the builder in its library as
`lib.mill-purifier.buildMillProject`:

```nix
{
  inputs.mill-purifier.url = "github:nix-purifiers/mill-purifier";
  inputs.nixpkgs.follows = "mill-purifier/nixpkgs";

  outputs = { nixpkgs, mill-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      build = mill-purifier.lib.mill-purifier.buildMillProject {
        inherit pkgs;
        src = ./.;
      };
    in
    {
      packages.${system}.core = build.packages.core;
      checks.${system}.tests = build.tests;
    };
}
```

`nix build '.#core'` builds the module `core`.

### What the builder takes and returns

`buildMillProject` takes `pkgs` and `src`, and these arguments, which
`nix/lib/build-mill-project.nix` documents:

- `fetchers`: the fetchers of the purifier library, such as a `fetchurl`
  that sends credentials or uses a company mirror. The default is the
  fetchers of nixpkgs.
- `lockFile`: the lockfile. The default is `mill-purifier.lock.json` in
  `src`, and a lockfile given here replaces any copy in `src`, so a
  packaging flake can build a project whose author keeps no lockfile.
- `jdk`: the JDK that runs Mill's launcher. The default is the headless
  OpenJDK 21 that `nix/lib/jdk.nix` names, which the `mill-purifier`
  command also uses.
- `git`: the commit the source is of, for a version from git (see
  [Versions from git](#versions-from-git)).
- `srcFilter`, and `allowStaleLock = true` to build from a stale lockfile.

It returns:

- `packages.<module>`, one per module that extends `PublishModule`, named
  by its module path, such as `core` or `foo.bar`. A package holds the
  files the module publishes in Maven layout, and its `artifacts`
  attribute holds each file by a name without the version, such as
  `packages.core.artifacts."core_3.jar"`. The names come from the
  lockfile, so Nix knows them when it evaluates.
- `tests`: the test tasks the lock run ran, run in the sandbox.
- `release`: every package published by Mill's own Maven publisher
  (`mill.javalib.MavenPublishModule`) into a Maven repository, with its
  checksums and `maven-metadata.xml`. It is what `publish` uploads.
- `fetches`: the entries of the lock, the downloads of the build as
  purifier library entries. An entry needed on one system only, such as a
  JVM archive, carries `systems`.
- `runTask "name" [ "core.run" ]`: a derivation that runs Mill with those
  arguments offline in the sandbox, and holds what Mill printed.
- `lock`: the lock in memory, as `readLock` gives it.

### Reading the lock

`lib.mill-purifier.readLock { src, lockFile ? src + "/mill-purifier.lock.json" }`
reads the lockfile into the shape that the purifier contract gives every
purifier: `{ purifier, entries, outputs, problems }`. A tool that reads
the downloads of every purifier, such as a software bill of materials
(SBOM) generator, calls it rather than parsing the lockfile.

- `entries` are the downloads, with their URLs and mirrors derived.
- `outputs.<module>` holds the `name` and the `artifacts` keys of each
  package.
- `problems` holds a message for a stale, tampered, malformed or
  other-version lockfile, each naming `mill-purifier lock`. It is empty
  for a usable lockfile. A lockfile that is not JSON fails evaluation.

The builder passes the result to `checkLock` of the purifier library,
which stops evaluation with the problems, and takes the entries of its
system from `entriesFor`.

The packages are deterministic. Mill writes the time of the build into its
jars, and the package build normalizes them with `strip-nondeterminism`.
It also sets `java.properties.date`, which replaces the date in the
`.properties` files that `java.util.Properties` writes, such as those of
Mill's BuildInfo plugin.

## Everyday loop

Mill has no plugin mechanism that reaches every build, so the everyday
loop goes through `mill-purifier mill`, which runs Mill's own launcher with
its arguments, offline, on the locked downloads:

```zsh
mill-purifier mill core.compile
mill-purifier mill core.test
mill-purifier mill core.run
```

To add or upgrade a dependency, edit `build.mill`, run `mill-purifier
lock`, and commit the lockfile. Until then `mill-purifier mill` warns that
the build definition changed, and a dependency that is not in the lock
fails to resolve, after which the command names `mill-purifier lock`.

`mill-purifier lock` runs the build in a copy without its `out/` directory,
so a lock never depends on what an earlier run left. `--tests <selector>`
chooses the test tasks the lock run runs, so that their runtime
dependencies are locked, and `--tests none` runs none:

```zsh
mill-purifier lock --tests 'os.jvm[2.13.18].test.testForked'
```

The default is every `testForked` task (`__.testForked`). The lockfile
records the selector (`testSelector`), a later `lock` without `--tests`
uses it again, and `tests` runs the test tasks the lock run ran. A test
that needs tools outside the JVM, such as a Scala Native test that needs
clang, needs them in the lock run and in the sandbox.

Mill has no lockfile of its own, and a version in `build.mill` names one
version, except for a version range such as `[2.9.0,2.11.0)`. Coursier
resolves a range against the version listing of the module
(`maven-metadata.xml`), and the lockfile records each listing that the
build needs. `lock` keeps the resolution: the lock run reads the listings
from the lockfile, so a range resolves as it did. `update` reads them
afresh and relocks, and with `org:artifact` names it does so only for
those modules:

```zsh
mill-purifier update
mill-purifier update org.typelevel:cats-kernel_3
```

Every command takes `--lockfile <path>` first, for a lockfile kept outside
the build. Without it, a command reads the environment variable
`MILL_PURIFIER_LOCKFILE`, so the dev shell of a packaging flake can set it
to the path the flake passes as `lockFile`.

A Mill daemon keeps the environment it was started with. Stop a daemon
that plain `./mill` started (`./mill shutdown`) before using
`mill-purifier mill`, and the other way around.

### Publishing

```zsh
mill-purifier publish mill.javalib.SonatypeCentralPublishModule/
```

builds every package with Nix, writes a Mill build whose `publishArtifacts`
tasks return the files of the packages, and runs the publisher on it.
Every Mill publisher takes the tasks to publish as `--publishArtifacts`,
and the command adds `--publishArtifacts __.publishArtifacts` unless the
arguments name it. Credentials and signing work as they do for the
publisher in a plain Mill build, through its environment variables and
arguments. Resolution runs online and starts from the locked downloads,
because a publisher can need libraries that the lock run did not use.

## Offline work

```zsh
mill-purifier prefetch
```

builds, with Nix, everything the lockfile lists for this system: the
downloads of the build and of its tests, the JVMs, and what an editor's
build server needs. Their garbage-collector roots are links in
`.mill-purifier/` beside the lockfile, and `.mill-purifier/prefetch.json`
records the store paths and the lockfile they were built from. After a prefetch,
`mill-purifier mill` needs neither Nix nor the network while the lockfile
stays the same, so the everyday loop and the editor work with the network
cut off. `mill-purifier mill` prefetches by itself when no prefetch of the
current lockfile exists.

The coursier caches Mill reads are trees of links into the store under
`~/.cache/mill-purifier`, outside the build, because Mill stops a task that
reads files in the workspace that the task does not declare as sources.

## Editor

Editors such as Metals (in VS Code) and IntelliJ IDEA talk to Mill through
the Build Server Protocol (BSP), and start Mill with the command in
`.bsp/mill-bsp.json`. Write that file through the purifier:

```zsh
mill-purifier mill mill.bsp.BSP/install
```

The command it names is a script under `~/.cache/mill-purifier` that runs
`mill-purifier mill` in the build, so the editor's Mill also runs offline
from the lockfile. The lock run starts Mill's BSP server and asks it what
an editor asks first (the build targets and the sources of their
dependencies), so the server's own libraries and the source jars an editor
shows are in the lock. The script names the mill-purifier package it was
written by; run the install again after updating mill-purifier.

## Errors and fixes

| What happened | What the error says | What to run |
|---|---|---|
| The build definition changed since the lock | `the build definition (…) changed since mill-purifier.lock.json was written` from Nix, and a warning from `mill-purifier mill` | `mill-purifier lock` |
| A dependency is not in the lock | Mill's resolution error, then `the lockfile lacks it` | `mill-purifier lock` |
| The lockfile was edited by hand | `does not match its contentHash` | `mill-purifier lock` |
| A download no longer matches its hash | Nix's `hash mismatch in fixed-output derivation`, then the command's note about it | `mill-purifier lock` |
| The lockfile is not a lockfile | `is not valid JSON` or `is not a mill-purifier lockfile` | `mill-purifier lock` |
| The lockfile is from another mill-purifier | `has lock format version …` | `mill-purifier lock` |
| No lockfile | `… does not exist; run mill-purifier lock first` | `mill-purifier lock` |

The lockfile records the hash of its own content (`contentHash`), and Nix
and the command both check it, so a hand edit fails before anything is
fetched.

## Sources supported and refused

The lock run records what coursier, the dependency resolver of Mill,
downloads, so it supports every source coursier resolves from:

- **Maven repositories**: Maven Central and every repository a module
  names in `repositories`, such as `https://maven.google.com`.
- **The meta-build**: the plugins and libraries of the build definition,
  such as `//| mvnDeps: ["com.lihaoyi::mill-contrib-buildinfo:$MILL_VERSION"]`.
- **Mill itself**: its launcher jar, `mill-dist-<version>.exe`, which the
  command downloads, and the Mill daemon, which the launcher resolves
  through coursier.
- **JVMs** that Mill downloads for its daemon (`mill-jvm-version`) or for a
  module (`jvmId`, `jvmVersion`), for x86_64-linux and aarch64-linux (see
  [JVMs](#jvms)).
- **Mill's Maven publisher**, which the lock run runs once into a local
  repository, so that `release` publishes offline.
- **Mill's BSP server** and the source jars editors read.
- **Version listings** (`maven-metadata.xml`) for version ranges and
  `latest` selectors, as described below.

It refuses, with the reason in the mechanism:

- **Mill 0.x**: Mill 1.x changed the build file format, the launcher and
  the way Mill resolves itself, and the lock run and the sandboxed build
  rely on the 1.x behavior.
- **`release` on Mill before 1.1.0**: Mill 1.1.0 is the first release with
  `mill.javalib.MavenPublishModule`, the Maven publisher that the lock run
  runs once and that `release` uses. A build on Mill 1.0.x or `1.1.0-RC1`
  locks without that step, and its packages and tests build. Its `release`
  fails when evaluated, with a message that names Mill 1.1.0.
- **Downloads that need credentials**: the lockfile records URLs and
  hashes, and no credentials. The build fetches them with credentials
  through `fetchers.fetchurl`, but a lock run cannot record them.
- **Files a build downloads outside coursier**: the lock run records what
  coursier downloads, so a file that build code fetches with its own HTTP
  client is in no lockfile. Two such builds are known. Kotlin's
  documentation tool, Dokka, fetches the package lists of external API
  documentation; in the sandbox it warns, and the generated documentation
  has no links to the Java and Kotlin standard library documentation. The
  build of os-lib defines `os.zip.apacheAntZipOriginalSource`, which
  downloads `ant-<version>-sources.jar` from Maven Central with
  `requests.get` and compiles it into the `os.zip` module, which every
  JVM module of os-lib depends on. Without network access that task
  fails, so the build fails in `__.compile`, and the lock run stops there.
- **Systems other than x86_64-linux and aarch64-linux**, for a build that
  asks for a JVM Mill downloads: the lock holds JVM archives for those two.
- Only modules that extend `PublishModule` become packages: Mill does not
  say which files any other module produces, while `publishArtifacts`
  names every file a published module produces.

### How the lock is made

`mill-purifier lock` copies the build to `out/mill-purifier/lock-run`, and
runs Mill there with an empty coursier cache. The run downloads Mill's
launcher from Maven Central, resolves the published modules
(`__.publishArtifacts`) and the test tasks, compiles every module, shows
the published files, starts the BSP server, runs the tests, and publishes
once into a local repository with Mill's Maven publisher. Every file the
run downloads goes into the lockfile as `{ path, hash }`, with `path` its
place in the coursier cache. The lockfile holds only what Nix cannot
derive: the URL follows from the path, as coursier stores
`https://host/a/b.jar` at `https/host/a/b.jar`, and a file from Maven
Central is also served by Google's mirror of it, so Nix expands each entry
into a file entry of the purifier library, `{ path, url, mirrors, hash }`.
The Mill version comes from the build, and the launcher from the version.

A `maven-metadata.xml` file lists the published versions of a module, and
its content changes whenever upstream publishes a version, so a hash of it
stops matching. The lock leaves listings out when an offline build of the
copy succeeds without them. When the build needs them, the lock keeps each
listing as the lock run read it, as an inline entry `{ path, contents }`,
and the offline build resolves to the versions the lock run picked.

The lockfile records a hash of the build definition (`definitionHash`):
the `*.mill` and `*.mill.yaml` files, everything under `mill-build/`, and
Mill's `.mill-*` and `.config/mill-*` settings files. `buildMillProject`
computes the same hash from the source, so it can tell a stale lockfile
from a current one.

When Maven Central rate-limits the machine, the lock run can resolve
through a mirror of it:

```zsh
MILL_PURIFIER_MAVEN_CENTRAL_MIRROR=https://maven-central.storage-download.googleapis.com/maven2 \
  mill-purifier lock
```

The lockfile is the same either way. It records each file at the path of
Maven Central, and the Nix build fetches it from Maven Central and then
from Google's mirror.

### JVMs

Mill runs its daemon on the JVM that `mill-jvm-version` names, which it
downloads through coursier by default, and a module that sets `jvmId` or
`jvmVersion` compiles and runs on a JVM that coursier downloads the same
way. Coursier unpacks such an archive into its archive cache, and the lock
records each archive the lock run unpacked. A prebuilt JDK expects a
filesystem hierarchy standard (FHS) system and does not run on Nix as
shipped, so `buildMillProject` unpacks each locked archive into the archive
cache itself and patches its executables and libraries with nixpkgs'
`autoPatchelfHook`. Coursier then finds the JVM unpacked and uses it.

Coursier chooses a JVM archive from a JVM index published for each
platform (`io.get-coursier.jvm.indices:index-linux-amd64`, and
`index-linux-arm64` for aarch64). The lock run finds the name and version
of each archive it unpacked in the index of its own platform, downloads the
index of the same version for the other Linux platform, and locks the
archive of the same JVM there. The lockfile holds both under `platforms`,
by Nix system, and a build reads only those of the system it builds for, so
one lockfile builds on x86_64-linux and aarch64-linux. A build that sets
`//| mill-jvm-version: system` and no module JVM runs Mill on a JDK from
nixpkgs and downloads no JVM.

On NixOS, a lock run for a build that asks for a downloaded JVM needs
nix-ld (or another way to run FHS binaries), because the lock run runs the
JVM before Nix has patched it.

### Versions from git

The Nix sandbox has no git repository: a flake's source has no `.git`
directory. Mill's `VcsVersion` (`mill.util.VcsVersionModule`) computes a
version from five git queries, and `buildMillProject` answers them with a
`git` command it puts in `PATH`, from what the caller says about the
commit:

```nix
buildMillProject {
  inherit pkgs;
  src = ./.;
  git = {
    inherit (self) rev revCount;
    # At or after a tag:
    tag = "v1.2.0";
    commitsSinceTag = 0;
  };
}
```

A commit at the tag gets the version `1.2.0`, and one 5 commits after it
gets `1.2.0-5-<six digits of rev>`, as VcsVersion formats them. The lock
cannot record the tag: tagging a release does not change the build
definition, so the lock would not be renewed, and the build would publish
the version of an old tag. Without `git`, VcsVersion sees no repository
and reports `no-vcs`, as it does for a source tree without git.

## Examples

CI locks and builds [fansi](https://github.com/com-lihaoyi/fansi) at the
tag 0.5.1, commit `387754bc1fc0be0ac787b195490275012d80c683`, as an example
of the purifier at work on an existing project. Its lockfile is
`tests/real-world/fansi.lock.json`. The project pins Mill 1.0.0 and has JVM,
Scala.js and Scala Native modules, each cross-built for Scala 2.12.20,
2.13.15 and 3.3.6, the MiMa plugin in the meta-build, and a version from
git. The lock run runs its JVM tests for Scala 2.13.15. The flake builds all
nine packages and runs those tests in the sandbox, and a CI job locks the
project again and compares the lockfile. Mill 1.0.0 has no Maven publisher,
so `release` is not available for it.

The fixtures in `tests/fixtures` cover the source kinds above:
`simple` (a Scala module with an munit suite, on the nixpkgs JDK) and
`polyglot` (Java, Kotlin and Scala modules, a custom repository, a
meta-build plugin, a version from git, a module JVM and the default daemon
JVM). `docs/development/testing.md` describes the checks.

## Credits

The design follows [sbt-nix-backend](https://github.com/clhodapp/sbt-nix-backend),
which does the same for sbt. The coursier cache code (`pkgs/cli/coursier_cache.py`)
is shared with the scala-cli purifier, and the download entries and their
trees come from the [purifier library](https://github.com/nix-purifiers/purifier).
