# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the mill-purifier command under
# `pkgs.mill-purifier` (`.cli`), and the builder `pkgs.buildMillProject`
# (nix/lib/build-mill-project.nix) beside it, where nixpkgs keeps its own
# builders, so a package written for callPackage takes it by name. A
# consumer that lists this flake in `projects` holds it as
# `mill-purifier/default`, which its package sets apply by default.
#
# The builder takes the purifier library (`lib.purifier`, from the
# nix-purifiers/purifier flake). The command takes the source of that
# flake, `closure-inputs.purifier`, because its interactive mode evaluates
# the builder with nixpkgs alone.
{ closure-inputs, closure-lib, ... }:
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
        inherit (closure-lib) purifier;
      };
    };
}
