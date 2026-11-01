# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the mill-purifier command under
# `pkgs.mill-purifier` (`.cli`). A consumer that lists this flake in
# `projects` holds it as `mill-purifier/default`, which its package sets
# apply by default. The builder is in the library, as
# `lib.mill-purifier.buildMillProject`.
#
# The command takes the source of the nix-purifiers/purifier flake,
# `closure-inputs.purifier`, because its interactive mode and its prefetch
# evaluate the builder with nixpkgs alone.
{ closure-inputs, closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay (callPackage: {
    cli = callPackage ../../pkgs/cli { purifierSource = closure-inputs.purifier; };
  }) "mill-purifier";
}
