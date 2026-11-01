# SPDX-License-Identifier: MIT
#
# The `mill-purifier` library namespace:
#
#   buildMillProject  the builder (nix/lib/build-mill-project.nix), which
#                     takes the package set as `pkgs`
#   readLock          the lockfile of a Mill build in the shape every
#                     purifier reads its lockfiles into
#                     (nix/lib/read-lock.nix), for the builder and for tools
#                     that read every purifier, such as an SBOM generator
#
# It imports the purifier library (`lib.purifier`), whose fetchers, tree,
# checkLock and entriesFor the builder uses.
{ ... }:
{

  imports = [ "purifier/default" ];

  overlay = final: prev: {
    mill-purifier = (prev.mill-purifier or { }) // {
      buildMillProject = import ../../nix/lib/build-mill-project.nix { inherit (final) purifier; };
      readLock = import ../../nix/lib/read-lock.nix;
    };
  };

}
