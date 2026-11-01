# The coursier cache of a lockfile: every locked file at its path in the
# cache, as a link into the store, laid out by the purifier library's
# `tree`. It holds the entries of the lock and those of its part for the
# system it is built for (lock.nix `platform`). It is a package for
# callPackage, with the lockfile among its arguments; buildMillProject's
# `dependencies` is this.
{
  pkgs,
  stdenv,
  purifier,
  lockFile,
  # Replaces nixpkgs' fetchurl for the locked downloads.
  fetchurl ? pkgs.fetchurl,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
in
purifier.tree {
  inherit pkgs fetchurl;
  name = "mill-coursier-cache";
  entries = lock.artifacts ++ (lock.platform stdenv.hostPlatform.system).artifacts;
}
