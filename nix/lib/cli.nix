# What the mill-purifier command builds: buildMillProject on the build root
# it runs in, with the nixpkgs and the purifier library of the command's
# own package. The interactive mode builds `dependencies` and
# `archiveCache`, which need only the lockfile; the publish verb builds
# `publishBuild`, which builds the packages.
#
#   nixpkgs         a nixpkgs source directory
#   purifierSource  the nix-purifiers/purifier source, whose default.nix
#                   takes { lib } and returns the library
#   src             the build root, as an absolute path string
{
  nixpkgs,
  purifierSource,
  src,
}:
let
  pkgs = import nixpkgs { };
  purifier = import purifierSource { inherit (pkgs) lib; };
  buildMillProject = pkgs.callPackage ./build-mill-project.nix { inherit purifier; };
in
buildMillProject { src = /. + src; }
