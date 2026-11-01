# SPDX-License-Identifier: MIT
#
# The `mill-purifier` library namespace. It holds nothing: the builder
# needs a package set, so it is the package `buildMillProject` that the
# default package overlay adds. It imports the purifier library
# (`lib.purifier`), which the builder takes.
{ ... }:
{

  imports = [ "purifier/default" ];

  overlay = final: prev: {
    mill-purifier = prev.mill-purifier or { };
  };

}
