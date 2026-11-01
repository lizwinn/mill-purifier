# mill-purifier

A command and a Nix library that build a [Mill](https://mill-build.org)
project in the Nix sandbox. Mill still plans the build. The command records
every file the build downloads in a lockfile, together with the modules the
build publishes, and Nix builds the project from that lockfile, offline,
without generated Nix files in the repository. mill-purifier is part of
[nix-purifiers](https://nix-purifiers.github.io). Its design follows
[sbt-nix-backend](https://github.com/clhodapp/sbt-nix-backend), which does
the same for sbt, and it shares its coursier cache code with the scala-cli
purifier.

- **A lockfile.** `mill-purifier lock` writes `mill-purifier.lock.json` at
  the build root. It records every file the build downloads, by URL and
  SHA-256: Mill itself, the plugins and libraries of the build definition,
  the dependencies of the modules and of their tests, Mill's Maven
  publisher, and the JVMs the build asks for. It also records each module
  the build publishes and the names of the files it publishes.
- **Sandboxed builds.** `buildMillProject`, which the flake's overlay adds
  to a package set, turns a build and its lockfile into derivations, with
  one package per published module. Nix knows every package and every file
  it publishes when it evaluates, from the lockfile alone.
- **Interactive Mill on the locked downloads.** `mill-purifier mill <args>`
  runs Mill offline, from the locked downloads, so a local build resolves
  exactly what the Nix build resolves.
- **Publishing what Nix built.** `mill-purifier publish <publisher> <args>`
  runs a Mill publisher, such as the Sonatype Central publisher, on the
  files the Nix sandbox built, and nothing is compiled outside the sandbox.

mill-purifier supports Mill 1.x, and Java, Kotlin and Scala modules.

## Use

Lock the build from its root and commit `mill-purifier.lock.json`:

```zsh
nix run github:nix-purifiers/mill-purifier -- lock
```

The build must pin its Mill version, in the `//| mill-version:` header of
`build.mill` or in `.mill-version`.

The flake's `overlays.default` adds `buildMillProject` to a package set,
and a package written for `callPackage` takes it by name, like any other
builder:

```nix
# package.nix
{ buildMillProject }:
(buildMillProject { src = ./.; }).packages.core
```

```nix
{
  inputs.mill-purifier.url = "github:nix-purifiers/mill-purifier";
  inputs.nixpkgs.follows = "mill-purifier/nixpkgs";

  outputs = { nixpkgs, mill-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          mill-purifier.overlays.default
          (final: prev: { core = final.callPackage ./package.nix { }; })
        ];
      };
    in
    {
      packages.${system}.core = pkgs.core;
    };
}
```

`nix build '.#core'` builds the module `core`.

### What the builder returns

`buildMillProject { src; }` returns:

- `packages.<module>`, one per module that extends `PublishModule`, named
  by its module path, such as `core` or `foo.bar`. A package holds the
  files the module publishes in Maven layout. Its `artifacts` attribute
  holds each file by a name without the version, such as
  `packages.core.artifacts."core_3.jar"`, `"core_3-sources.jar"`,
  `"core_3-javadoc.jar"` and `"core_3.pom"`.
- `repository`, every package published by Mill's own Maven publisher
  (`mill.javalib.MavenPublishModule`) into a Maven repository, with its
  checksums and `maven-metadata.xml`.
- `runTask`, a function: `runTask "name" [ "core.run" ]` is a derivation
  that runs Mill with those arguments offline in the sandbox, and holds
  what Mill printed.
- `dependencies` and `archiveCache`, the coursier caches the builds read.
- `publishBuild`, the Mill build that `publish` runs a publisher on.

The arguments, documented in `nix/lib/build-mill-project.nix`, are `src`,
`lockFile`, `jdk`, `fetchurl` (for credentials or mirrors), `doCheck`
(runs each module's tests in its package build), `git` (see below) and
`srcFilter`.

The packages are deterministic. Mill writes the time of the build into its
jars, and the package build normalizes them with `strip-nondeterminism`.
It also sets `java.properties.date`, which replaces the date in the
`.properties` files that `java.util.Properties` writes, such as those of
Mill's BuildInfo plugin.

### Interactive mode

```zsh
mill-purifier mill core.run
```

runs Mill from the build root with its arguments. The command builds the
locked downloads and JVMs with Nix (their GC roots are links under
`out/mill-purifier`) into coursier caches of links into the store under
`~/.cache/mill-purifier`, and runs the locked Mill launcher with those
caches in offline mode. The caches live outside the build, because Mill
stops a task that reads files in the workspace that the task does not
declare as sources. A dependency that is not in the lockfile fails to
resolve. When the build definition changed since the lockfile was made,
the command warns and runs from the old lock until `mill-purifier lock`
renews it.

A Mill daemon keeps the environment it was started with. Stop a daemon
that plain `./mill` started (`./mill shutdown`) before using interactive
mode, and the other way around.

### Editors

Editors such as Metals (in VS Code) and IntelliJ IDEA talk to Mill through
the Build Server Protocol (BSP), and start Mill with the command in
`.bsp/mill-bsp.json`. Write that file through interactive mode:

```zsh
mill-purifier mill mill.bsp.BSP/install
```

The command it names is a script under `~/.cache/mill-purifier` that runs
`mill-purifier mill` in the build, so the editor's Mill also runs offline
from the lockfile. The script names the mill-purifier package it was
written by; run the install again after updating mill-purifier.

### Common errors

| What happened | What the error says | What to run |
|---|---|---|
| The build definition changed since the lock | `the build definition (…) changed since mill-purifier.lock.json was written` from Nix, and a warning from interactive mode | `mill-purifier lock` |
| A dependency is not in the lock | Mill's resolution error, then `the lockfile lacks it` from the Nix build | `mill-purifier lock`, or `relock` |
| A hash in the lockfile was edited | Nix's `hash mismatch in fixed-output derivation`, then the command's note about it | `mill-purifier relock` |
| The lockfile is not a lockfile | `is not valid JSON` or `is not a mill-purifier lockfile` | `mill-purifier relock` |
| The lockfile is from another mill-purifier | `has lock format version …` | `mill-purifier relock` |
| No lockfile | `has no mill-purifier.lock.json` | `mill-purifier lock` |

`buildMillProject { checkLock = false; }` builds from a stale lockfile
anyway.

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

### Versions from git

The Nix sandbox has no git repository: a flake's source has no `.git`
directory. Mill's `VcsVersion` (`mill.util.VcsVersionModule`) computes a
version from five git queries, and `buildMillProject` answers them with a
`git` command it puts in `PATH`, from what the caller says about the
commit:

```nix
buildMillProject {
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

## How the lock is made

`mill-purifier lock` copies the build, without its `out/` directory, to
`out/mill-purifier/lock-run`, and runs Mill there with an empty coursier
cache (coursier is the dependency resolver that Mill uses). The run
downloads Mill's launcher from Maven Central, resolves the published
modules (`__.publishArtifacts`) and the test tasks (`__.testForked`),
compiles every module, shows the published files, runs the tests, and
publishes once into a local repository with Mill's Maven publisher, so that
the publisher's libraries are in the lock too. It also starts Mill's BSP
server and asks it what an editor asks first (the build targets and the
sources of their dependencies), so the server's libraries and the source
jars an editor shows are in the lock. Every file the run downloads goes
into the lockfile.

Mill resolves everything through coursier, including Mill itself, so the
lockfile needs no list of what Mill fetches. The one file outside coursier
is the launcher jar, `mill-dist-<version>.exe`, which the command downloads
itself.

A `maven-metadata.xml` file lists the published versions of a module, and
its content changes whenever upstream publishes a version, so a hash of it
stops matching. The lock leaves listings out when an offline build of the
copy succeeds without them. When the build needs them, for a version range
or a `latest` selector, the lock keeps each listing as the lock run read it,
as an inline entry, and the offline build resolves to the versions the lock
run picked.

`mill-purifier lock` relocks only when the build definition changed: the
`*.mill` and `*.mill.yaml` files, everything under `mill-build/`, and
Mill's `.mill-*` and `.config/mill-*` settings files. `mill-purifier relock`
relocks regardless. The lockfile records a hash of these files
(`definitionHash`), and `buildMillProject` computes the same hash from the
source, so it can tell a stale lockfile from a current one.

`--tests <selector>` chooses the test tasks the lock run runs, so that their
runtime dependencies are locked, and `--tests none` runs none:

```zsh
mill-purifier lock --tests 'os.jvm[2.13.18].test.testForked'
```

The default is every `testForked` task (`__.testForked`). The lockfile
records the selector (`testSelector`), a later `lock` or `relock` without
`--tests` uses it again, and `doCheck` runs the test tasks the lock run ran.
A test that needs tools outside the JVM, such as a Scala Native test that
needs clang, needs them in the lock run and in the package build.

When Maven Central rate-limits the machine, the lock run can resolve
through a mirror of it:

```zsh
MILL_PURIFIER_MAVEN_CENTRAL_MIRROR=https://maven-central.storage-download.googleapis.com/maven2 \
  mill-purifier relock
```

The lockfile is the same either way. It records each file at the path and
URL of Maven Central, and every Maven Central entry names Google's mirror in
`mirrors`, which the Nix build tries when Maven Central fails.

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
nixpkgs and downloads no JVM. The headless OpenJDK of the major version the
lock was made with runs the launcher, and `jdk` replaces it.

## Limits

- Mill 0.x builds are not supported. Mill 1.x changed the build file
  format, the launcher and the way Mill resolves itself, and the lock run
  and the sandboxed build rely on the 1.x behavior.
- Only modules that extend `PublishModule` become packages. Mill does not
  say which files any other module produces, while `publishArtifacts`
  names every file a published module produces.
- A lock covers x86_64-linux and aarch64-linux. A build on another system,
  such as macOS, needs JVM archives the lock does not hold whenever the
  build asks for a JVM Mill downloads.
- On NixOS, a lock run for a build that asks for a downloaded JVM needs
  nix-ld (or another way to run FHS binaries), because the lock run runs
  the JVM before Nix has patched it.
- Downloads that need credentials cannot be locked, because the lockfile
  records URLs and hashes and no credentials.
- Files a build downloads outside coursier are not locked. Kotlin's
  documentation tool, Dokka, fetches the package lists of external API
  documentation; in the sandbox it warns, and the generated documentation
  has no links to the Java and Kotlin standard library documentation.
