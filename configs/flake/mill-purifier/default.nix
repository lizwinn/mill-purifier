# SPDX-License-Identifier: MIT
{ ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };

    # The package scope `mill-purifier` is the `default` entry of this
    # flake's package overlay registry (pkg-overlays/): the package set
    # applies it by default, and the flake exports it as `pkgOverlays` and
    # as the plain `overlays.default`. The scope holds the builder, which is
    # a function and not a package, so the flake exports its packages below
    # by name and not as the whole scope.
  };

  # `nix run github:nix-purifiers/mill-purifier -- lock` locks the Mill
  # build in the current directory.
  perSystem =
    { pkgs, ... }:
    {
      packages = {
        cli = pkgs.mill-purifier.cli;
        default = pkgs.mill-purifier.cli;
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              # The flake's default package overlay, which adds buildMillProject.
              overlay = self.overlays.default;
              millPurifier = self.lib.mill-purifier;
              inherit (self.packages.${system}) cli;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
