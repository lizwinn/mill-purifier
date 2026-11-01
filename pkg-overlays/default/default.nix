# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the mill-purifier command under
# `pkgs.mill-purifier` (`.cli`), and the builder `pkgs.buildMillProject`
# (nix/lib/build-mill-project.nix) beside it, where nixpkgs keeps its own
# builders, so a package written for callPackage takes the builder by name.
# A consumer that lists this flake in `projects` holds the overlay as
# `mill-purifier/default`, which its package sets apply by default.
#
# The command takes the source of the nix-purifiers/purifier flake,
# `closure-inputs.purifier`, because its interactive mode and its prefetch
# evaluate the builder with nixpkgs alone. The builder takes the library of
# that flake, `closure-lib.purifier`.
{
  closure-inputs,
  closure-lib,
  ...
}:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay (callPackage: {
    cli = callPackage ../../pkgs/cli { purifierSource = closure-inputs.purifier; };
  }) "mill-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildMillProject = final.callPackage ../../nix/lib/build-mill-project.nix {
        purifier = closure-lib.purifier;
      };
    };
}
