# Reads a mill-purifier lockfile (written by `mill-purifier lock`), and
# stops with the command to run when the file is not one this library
# reads. Its `artifacts`, and the `artifacts` of each platform, are entries
# of the purifier library: files { path, url, mirrors, hash } and inline
# files { path, contents }.
{ lockFile }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

  required = [
    "version"
    "millVersion"
    "javaVersion"
    "launcher"
    "definitionHash"
    "projects"
    "artifacts"
  ];
  missing = builtins.filter (field: !(lock ? ${field})) required;
in
assert
  builtins.isAttrs lock
  || throw "mill-purifier: ${toString lockFile} is not a mill-purifier lockfile (it holds no JSON object); run `mill-purifier relock` in the build root.";
assert
  missing == [ ]
  || throw "mill-purifier: ${toString lockFile} is not a mill-purifier lockfile; it has no ${builtins.concatStringsSep ", " missing}. Run `mill-purifier relock` in the build root.";
assert
  lock.version == supportedVersion
  || throw "mill-purifier: ${toString lockFile} has lock format version ${toString lock.version}; this library reads version ${toString supportedVersion}. Run `mill-purifier relock` with the mill-purifier version that provides this library.";
lock
// {
  testTasks = lock.testTasks or [ ];

  # The part of the lock for one Nix system: the coursier JVM index and the
  # JVM archives coursier downloads there (`artifacts`), and the archives
  # it unpacks (`archives`, see archive-cache.nix). A lock whose build
  # downloads no JVM has no platform-specific part.
  platform =
    system:
    let
      platforms = lock.platforms or { };
    in
    if platforms == { } then
      {
        artifacts = [ ];
        archives = [ ];
      }
    else
      platforms.${system}
        or (throw "mill-purifier: ${toString lockFile} locks the JVMs of the build for ${builtins.concatStringsSep " and " (builtins.attrNames platforms)}, not for ${system}.");

  projectsById = builtins.listToAttrs (
    map (p: {
      name = p.id;
      value = p;
    }) lock.projects
  );
}
