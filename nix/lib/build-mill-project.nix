# buildMillProject: the sandboxed builds of a Mill build, from the lockfile
# that `mill-purifier lock` writes at the build root.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# mill-purifier overlay (`overlays.default`) adds it to the package set as
# `buildMillProject`, so a package written for callPackage takes it like
# any other dependency:
#
#   { buildMillProject }: (buildMillProject { src = ./.; }).packages.core
#
# and `buildMillProject.override` replaces what it takes from the set. The
# builder returns
#
#   dependencies   the coursier download cache of every locked file
#   archiveCache   the coursier archive cache: the locked archives (JDKs),
#                  unpacked and patched for Nix
#   packages.<id>  the published artifacts of the Mill module <id> (its
#                  module path, such as `core` or `foo.bar`), in Maven
#                  layout
#   publishBuild   a Mill build whose `publishArtifacts` tasks return the
#                  files of the packages, for Mill's publishers
#   repository     every package published by Mill's own Maven publisher
#                  (mill.javalib.MavenPublishModule) into a Maven repository
#   runTask        runTask name [ args ]: a derivation that runs Mill with
#                  `args` offline in the sandbox, such as [ "core.run" ],
#                  with what Mill prints in `out`
#   jdk            the JDK that runs Mill
{
  lib,
  stdenvNoCC,
  runCommand,
  callPackage,
  jq,
  strip-nondeterminism,
  # The JDKs a build can run on; the default JDK of a build is the headless
  # one of the major version its lock was made with.
  javaPackages,
  # The purifier library (`lib.purifier` of nix-purifiers/purifier), which
  # fetches the locked downloads and lays them out; the package overlay
  # passes it.
  purifier,
}:
{
  # The root of the Mill build.
  src,
  # The lockfile; the default is the one `mill-purifier lock` writes at the
  # build root.
  lockFile ? src + "/mill-purifier.lock.json",
  # The JDK that runs Mill's launcher, and Mill's daemon when the build sets
  # `mill-jvm-version: system`.
  jdk ? null,
  # Replaces nixpkgs' fetchurl for the locked downloads, such as a fetchurl
  # with credentials. It takes the arguments the purifier library passes to
  # nixpkgs' fetchurl.
  fetchurl ? null,
  # Runs the tests of each module (the `testForked` tasks the lock recorded
  # under the module) in its package build.
  doCheck ? false,
  # The git commit the source is of, for a build that computes its version
  # from git (Mill's VcsVersion): { rev, revCount, tag, commitsSinceTag }.
  # A flake passes { inherit (self) rev revCount; } and, at or after a tag,
  # `tag` and `commitsSinceTag`. See git-shim.nix. The default gives the
  # build no git, which VcsVersion reports as `no-vcs`.
  git ? null,
  # Filters the build root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out build outputs and
  # editor state.
  srcFilter ? null,
  # Stops the build when the build definition differs from the one the lock
  # was made from (a stale lock).
  checkLock ? true,
}:
let
  lock' = import ./lock.nix { inherit lockFile; };
  definition = import ./definition-hash.nix src;
  lock =
    assert
      !checkLock
      || definition.hash == lock'.definitionHash
      || throw "mill-purifier: the build definition (${lib.concatStringsSep ", " definition.files}) changed since ${toString lockFile} was written, so the lock may miss what the build now downloads. Run `mill-purifier lock` in the build root and commit the lockfile, or pass `checkLock = false` to build from it anyway.";
    lock';

  # Build outputs and editor state never take part in a build.
  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
    in
    !(
      (type == "directory" && (name == "out" || name == ".bsp" || name == ".metals" || name == ".bloop"))
      || name == ".git"
      || name == ".idea"
      || lib.hasPrefix "result" name
    );

  filteredSrc = builtins.path {
    path = src;
    name = "mill-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  defaultJdk =
    javaPackages.compiler."openjdk${lock.javaVersion}".headless
      or (throw "mill-purifier: javaPackages has no openjdk${lock.javaVersion} for the Java ${lock.javaVersion} the lock was made with; pass `jdk`.");
  jdk' = if jdk != null then jdk else defaultJdk;

  # callPackage passes nixpkgs' fetchurl unless the caller gave another.
  fetchArgs = {
    inherit lockFile purifier;
  }
  // lib.optionalAttrs (fetchurl != null) { inherit fetchurl; };
  dependencies = callPackage ./dependencies.nix fetchArgs;
  archiveCache = callPackage ./archive-cache.nix fetchArgs;
  gitShim = if git == null then null else callPackage ./git-shim.nix { } git;

  # The Mill invocation shared by every build from the lock;
  # `mill-purifier lock` runs Mill the same way, so a lock made from it holds
  # what this needs. It is one subshell, so a redirection after it takes the
  # output of Mill.
  runMill = args: ''
    (
    export HOME="$TMPDIR/home"
    export XDG_RUNTIME_DIR="$TMPDIR/run"
    export XDG_CACHE_HOME="$HOME/.cache" XDG_CONFIG_HOME="$HOME/.config"
    export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
    export COURSIER_CACHE="$TMPDIR/coursier-cache"
    export COURSIER_ARCHIVE_CACHE="$TMPDIR/coursier-archive-cache"
    export COURSIER_MODE=offline
    # Mill passes JAVA_OPTS to the JVM it starts for its daemon.
    # java.properties.date replaces the time of the build in the comment
    # that java.util.Properties.store writes (Java 18 and later), as in the
    # files Mill's BuildInfo plugin writes.
    export JAVA_OPTS="-Duser.home=$HOME -Djava.io.tmpdir=$TMPDIR/java-tmp -Djava.properties.date=1980-01-01T00:00:00Z"
    ${lib.optionalString (gitShim != null) ''export PATH="${gitShim}/bin:$PATH"''}
    if [ ! -d "$COURSIER_CACHE" ]; then
      mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$TMPDIR/java-tmp" "$COURSIER_CACHE" "$COURSIER_ARCHIVE_CACHE"
      # Coursier writes lock and marker files next to what it reads, so the
      # caches are writable trees of links into the store.
      cp -rs --no-preserve=mode ${dependencies}/. "$COURSIER_CACHE"
      cp -rs --no-preserve=mode ${archiveCache}/. "$COURSIER_ARCHIVE_CACHE"
    fi
    java $JAVA_OPTS -jar "$COURSIER_CACHE/${lock.launcher}" \
      --no-daemon --ticker false ${args} </dev/null || {
      echo "mill-purifier: Mill failed in the Nix sandbox, offline, with only the downloads of the lockfile." >&2
      echo "mill-purifier: if it reports a file it could not find or download, the lockfile lacks it: run \`mill-purifier lock\` (or \`mill-purifier relock\`) in the build root and commit the lockfile." >&2
      exit 1
    }
    )'';

  # The build links each artifact at a name without the version of the
  # module: <linkDirectory>/<key>, such as nix-support/artifacts/core_3.jar.
  linkDirectory = "nix-support/artifacts";
  artifactFile = package: key: "${package}/${linkDirectory}/${key}";

  mkPackage =
    project:
    let
      tests = lib.filter (t: lib.hasPrefix "${project.id}." t) lock.testTasks;
    in
    stdenvNoCC.mkDerivation (finalAttrs: {
      inherit (project) name;
      src = filteredSrc;
      nativeBuildInputs = [
        jdk'
        jq
        strip-nondeterminism
      ];
      dontConfigure = true;
      # The outputs are jars and POMs; fixup has nothing to patch, and it
      # must not rewrite them.
      dontFixup = true;
      buildPhase = ''
        runHook preBuild
        ${
          runMill (
            lib.escapeShellArgs [
              "show"
              "${project.id}.publishArtifacts"
            ]
          )
        } > "$TMPDIR/publish.json"
        ${lib.optionalString (doCheck && tests != [ ]) (
          runMill (lib.escapeShellArgs (lib.intersperse "+" tests))
        )}
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        group=$(jq -r .meta.group "$TMPDIR/publish.json")
        id=$(jq -r .meta.id "$TMPDIR/publish.json")
        version=$(jq -r .meta.version "$TMPDIR/publish.json")
        dir="''${group//.//}/$id/$version"
        mkdir -p "$out/$dir" "$out/${linkDirectory}"
        # Each payload entry is [path reference, published file name]; a
        # path reference is `ref:<version>:<signature>:<path>` (or `qref:`).
        jq -r '.payload[] | [(.[0] | sub("^q?ref:[^:]*:[^:]*:"; "")), .[1]] | @tsv' \
          "$TMPDIR/publish.json" |
          while IFS=$'\t' read -r file name; do
            cp "$file" "$out/$dir/$name"
            rest=''${name#"$id-$version"}
            ln -s "../../$dir/$name" "$out/${linkDirectory}/$id$rest"
          done
        # Mill writes the time of the build into its jars (zip entry times,
        # and the dates javadoc writes into its pages); the package sets them
        # to SOURCE_DATE_EPOCH, so a build of the same source gives the same
        # files.
        find "$out/$dir" -name '*.jar' -exec strip-nondeterminism --type jar {} +
        for key in ${lib.escapeShellArgs (map (a: a.key) project.artifacts)}; do
          if [ ! -e "$out/${linkDirectory}/$key" ]; then
            echo "mill-purifier: the lock names $key, which this build of ${project.id} did not publish; run mill-purifier lock" >&2
            exit 1
          fi
        done
        # What publishBuild publishes: the coordinates and the files, by the
        # names they are published under.
        jq --arg dir "$out/$dir" \
          '{group: .meta.group, id: .meta.id, version: .meta.version,
            files: [.payload[] | {name: .[1], path: ($dir + "/" + .[1])}]}' \
          "$TMPDIR/publish.json" > "$out/nix-support/publish.json"
        runHook postInstall
      '';
      passthru = {
        inherit dependencies lock;
        millProject = project;
        # The artifact files of the package by key, such as
        # artifacts."core_3-sources.jar". They are known from the lock
        # alone, before the package is built.
        artifacts = builtins.listToAttrs (
          map (a: {
            name = a.key;
            value = artifactFile finalAttrs.finalPackage a.key;
          }) project.artifacts
        );
      };
      meta.description = "${project.organization}:${project.name}, built by mill-purifier";
    });

  packages = builtins.mapAttrs (_: mkPackage) lock.projectsById;

  # A Mill build with one module per package, whose `publishArtifacts` task
  # returns the files of the package. Mill's publishers take the tasks to
  # publish as `--publishArtifacts`, so `__.publishArtifacts` publishes what
  # Nix built. Its modules are named m0, m1, … in the order of the lock;
  # each has a comment naming the module it publishes.
  publishBuild =
    runCommand "mill-publish-build"
      {
        nativeBuildInputs = [ jq ];
        preferLocalBuild = true;
      }
      ''
        mkdir -p $out
        {
          echo '//| mill-version: ${lock.millVersion}'
          echo '//| mill-jvm-version: system'
          echo 'package build'
          echo 'import mill.*, mill.javalib.*, mill.javalib.publish.*'
          ${lib.concatImapStrings (i: p: ''
            echo
            echo ${lib.escapeShellArg "// ${p.id}"}
            jq -r --arg name ${lib.escapeShellArg "m${toString (i - 1)}"} '
              "object \($name) extends Module {\n" +
              "  def publishArtifacts = Task {\n" +
              "    PublishModule.PublishData(\n" +
              "      Artifact(\(.group | tojson), \(.id | tojson), \(.version | tojson)),\n" +
              "      Seq(\n" +
              ([.files[] | "        PathRef(os.Path(\(.path | tojson))) -> \(.name | tojson)"] | join(",\n")) +
              "\n      )\n    )\n  }\n}"' ${packages.${p.id}}/nix-support/publish.json
          '') lock.projects}
        } > $out/build.mill
      '';

  # Mill's MavenPublishModule publishes publishBuild into a file:
  # repository, offline: the lock run publishes the same way once, so the
  # publisher's dependencies are in the lock.
  repository = stdenvNoCC.mkDerivation {
    name = "mill-repository";
    src = publishBuild;
    nativeBuildInputs = [ jdk' ];
    dontConfigure = true;
    dontFixup = true;
    buildPhase = ''
      runHook preBuild
      chmod -R u+w .
      export MILL_MAVEN_USERNAME=local MILL_MAVEN_PASSWORD=local
      ${runMill ''
        mill.javalib.MavenPublishModule/publishAll \
          --publishArtifacts __.publishArtifacts \
          --releaseUri "file://$out" --snapshotUri "file://$out"''}
      runHook postBuild
    '';
    dontInstall = true;
  };
  runTask =
    name: args:
    stdenvNoCC.mkDerivation {
      inherit name;
      src = filteredSrc;
      nativeBuildInputs = [ jdk' ];
      dontConfigure = true;
      dontFixup = true;
      buildPhase = ''
        runHook preBuild
        ${runMill (lib.escapeShellArgs args)} > "$TMPDIR/stdout"
        runHook postBuild
      '';
      installPhase = ''
        cp "$TMPDIR/stdout" $out
      '';
    };
in
{
  inherit
    lock
    dependencies
    archiveCache
    packages
    publishBuild
    repository
    runTask
    ;
  jdk = jdk';
}
