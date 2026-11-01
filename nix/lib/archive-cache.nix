# The coursier archive cache of a lockfile. Coursier unpacks an archive it
# downloaded, such as the JDK that Mill's `mill-jvm-version` or a module's
# `jvmId` asks for, into <archive cache>/<path of the archive in the
# download cache>/. The lock records each archive the lock run unpacked
# (`archives` of each platform), and this places each one there, unpacked,
# with its ELF files patched by autoPatchelfHook so that they run on Nix
# rather than on a filesystem hierarchy standard (FHS) system. Coursier
# finds the directory and does not unpack the archive again.
#
#   pkgs        the package set
#   platform    the part of the lock for the system of `pkgs`
#   fetchEntry  the fetcher of the purifier library, bound to its fetchers
{
  pkgs,
  platform,
  fetchEntry,
}:
let
  inherit (pkgs) lib stdenv runCommand;
  byPath = builtins.listToAttrs (
    map (a: {
      name = a.path;
      value = a;
    }) platform.artifacts
  );

  unpack =
    path:
    let
      artifact =
        byPath.${path}
          or (throw "mill-purifier: the lock names the archive ${path}, which it does not download; run `mill-purifier lock`");
    in
    stdenv.mkDerivation {
      name = "${builtins.baseNameOf path}-unpacked";
      src = fetchEntry artifact;
      dontUnpack = true;
      dontConfigure = true;
      dontBuild = true;
      # A JDK keeps its own debug information and must stay as shipped.
      dontStrip = true;
      nativeBuildInputs = [
        pkgs.autoPatchelfHook
        pkgs.unzip
      ];
      # What a headless JDK links against. The AWT, sound and font
      # libraries of a JDK link against X11, ALSA and fontconfig, which a
      # build never loads, so missing dependencies are not an error.
      buildInputs = [
        stdenv.cc.cc.lib
        pkgs.zlib
      ];
      autoPatchelfIgnoreMissingDeps = [ "*" ];
      installPhase = ''
        runHook preInstall
        mkdir -p $out
        case ${lib.escapeShellArg path} in
          *.zip) unzip -q "$src" -d "$out" ;;
          *) tar -xf "$src" -C "$out" ;;
        esac
        runHook postInstall
      '';
    };
in
runCommand "mill-coursier-archive-cache"
  {
    preferLocalBuild = true;
    allowSubstitutes = false;
  }
  ''
    mkdir -p $out
    ${lib.concatMapStrings (path: ''
      mkdir -p "$out/$(dirname ${lib.escapeShellArg path})"
      ln -s ${unpack path} "$out/"${lib.escapeShellArg path}
    '') platform.archives}
  ''
