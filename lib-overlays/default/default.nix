# SPDX-License-Identifier: MIT
#
# The `mill-purifier` library namespace: the builder `buildMillProject`
# (nix/lib/build-mill-project.nix), which takes the package set as `pkgs`.
# It imports the purifier library (`lib.purifier`), which the builder uses
# to fetch the locked downloads.
{ ... }:
{

  imports = [ "purifier/default" ];

  overlay = final: prev: {
    mill-purifier = (prev.mill-purifier or { }) // {
      buildMillProject = import ../../nix/lib/build-mill-project.nix { inherit (final) purifier; };
    };
  };

}
