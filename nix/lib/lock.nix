# Reads a mill-purifier lockfile (written by `mill-purifier lock`), and
# stops with the command to run when the file is not one this library
# reads.
#
# A download is recorded as { path, hash }: its place in the coursier
# cache, and the hash of the file. Its URL follows from the path (coursier
# stores `https://host/a/b.jar` at `https/host/a/b.jar`), and a file from
# Maven Central is also served by Google's mirror of it, so this expands
# each one into a file entry of the purifier library,
# { path, url, mirrors, hash }. An inline entry { path, contents } holds a
# version listing as the lock run read it.
{ lockFile }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

  required = [
    "version"
    "contentHash"
    "definitionHash"
    "projects"
    "artifacts"
  ];
  missing = builtins.filter (field: !(lock ? ${field})) required;

  mavenCentral = "https://repo1.maven.org/maven2";
  mavenCentralMirror = "https://maven-central.storage-download.googleapis.com/maven2";
  hasPrefix = prefix: s: builtins.substring 0 (builtins.stringLength prefix) s == prefix;
  dropPrefix = prefix: s: builtins.substring (builtins.stringLength prefix) (-1) s;

  # Coursier escapes a character as % and two hex digits of its character
  # code (url_of in pkgs/cli/coursier_cache.py), and a JSON string decodes
  # \u00XX to that character.
  unescape =
    s:
    builtins.concatStringsSep "" (
      map (
        part: if builtins.isList part then builtins.fromJSON ''"\u00${builtins.head part}"'' else part
      ) (builtins.split "%([0-9A-Fa-f]{2})" s)
    );

  # The URL a cache path was downloaded from.
  urlOf =
    path:
    let
      decoded = unescape path;
      m = builtins.match "([^/]+)/(([^/]*).*)" decoded;
      protocol = builtins.elemAt m 0;
      rest = builtins.elemAt m 1;
      host = builtins.elemAt m 2;
      rest' =
        if builtins.match ".*/\\.directory" rest != null then
          builtins.substring 0 (builtins.stringLength rest - 10) rest
        else
          rest;
    in
    assert
      m != null
      || throw "mill-purifier: ${toString lockFile} holds ${path}, which is not a coursier cache path; run `mill-purifier lock`.";
    assert
      builtins.match ".*@.*" host == null
      || throw "mill-purifier: ${toString lockFile} holds ${path}, which was downloaded with credentials; run `mill-purifier lock`.";
    "${protocol}://${rest'}";

  expand =
    entry:
    if entry ? contents then
      entry
    else
      let
        url = urlOf entry.path;
      in
      {
        inherit (entry) path hash;
        inherit url;
        mirrors =
          if hasPrefix "${mavenCentral}/" url then
            [ "${mavenCentralMirror}${dropPrefix mavenCentral url}" ]
          else
            [ ];
      };

  # The coursier JVM index, the one download of a platform that is not a JVM
  # archive.
  jvmIndexDir = "https/repo1.maven.org/maven2/io/get-coursier/jvm/indices/";
in
assert
  builtins.isAttrs lock
  || throw "mill-purifier: ${toString lockFile} is not a mill-purifier lockfile (it holds no JSON object); run `mill-purifier lock` in the build root.";
assert
  missing == [ ]
  || throw "mill-purifier: ${toString lockFile} is not a mill-purifier lockfile; it has no ${builtins.concatStringsSep ", " missing}. Run `mill-purifier lock` in the build root.";
assert
  lock.version == supportedVersion
  || throw "mill-purifier: ${toString lockFile} has lock format version ${toString lock.version}; this library reads version ${toString supportedVersion}. Run `mill-purifier lock` with the mill-purifier version that provides this library.";
# The content hash is the SHA-256 of the lockfile without `contentHash`, as
# compact JSON with sorted keys (content_hash in pkgs/cli/mill_purifier.py),
# which is what builtins.toJSON writes.
assert
  lock.contentHash
  == "sha256:" + builtins.hashString "sha256" (builtins.toJSON (removeAttrs lock [ "contentHash" ]))
  || throw "mill-purifier: ${toString lockFile} does not match its contentHash: it was changed after `mill-purifier lock` wrote it, as by a hand edit. Run `mill-purifier lock` in the build root and commit the lockfile.";
lock
// {
  testTasks = lock.testTasks or [ ];

  # The downloads and inline files of every system, as purifier library
  # entries.
  artifacts = map expand lock.artifacts;

  # The part of the lock for one Nix system: the coursier JVM index and the
  # JVM archives coursier downloads there (`artifacts`), and the archives
  # it unpacks (`archives`, see archive-cache.nix): every one of them but
  # the index. A lock whose build downloads no JVM has no platform-specific
  # part.
  platform =
    system:
    let
      platforms = lock.platforms or { };
      part =
        platforms.${system}
          or (throw "mill-purifier: ${toString lockFile} locks the JVMs of the build for ${builtins.concatStringsSep " and " (builtins.attrNames platforms)}, not for ${system}.");
    in
    if platforms == { } then
      {
        artifacts = [ ];
        archives = [ ];
      }
    else
      {
        artifacts = map expand part.artifacts;
        archives = map (a: a.path) (builtins.filter (a: !(hasPrefix jvmIndexDir a.path)) part.artifacts);
      };

  projectsById = builtins.listToAttrs (
    map (p: {
      name = p.id;
      value = p;
    }) lock.projects
  );
}
