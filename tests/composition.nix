# SPDX-License-Identifier: MIT
{
  pkgs,
  build,
  purifier,
}:
let
  baseline = build { src = ./fixtures/simple; };
  fetch =
    module: suffix:
    purifier.fetchEntry { inherit pkgs; } (
      builtins.head (
        builtins.filter (
          entry:
          entry.path
          == "https/repo1.maven.org/maven2/com/lihaoyi/${module}_3/4.1.0/${module}_3-4.1.0${suffix}"
        ) baseline.fetches
      )
    );
  makeProvider =
    module:
    let
      result =
        pkgs.runCommand "mill-${module}-provider"
          {
            nativeBuildInputs = [ pkgs.python3 ];
            passthru.projections = purifier.jvmProjections {
              repository = result;
              inherit (pkgs) runCommand python3;
            };
          }
          ''
            directory=$out/com/lihaoyi/${module}_3/0.0.1
            mkdir -p "$directory"
            cp ${fetch module ".jar"} "$directory/${module}_3-0.0.1.jar"
            cp ${fetch module "-sources.jar"} "$directory/${module}_3-0.0.1-sources.jar"
            export ORIGINAL=${fetch module ".pom"} TARGET="$directory/${module}_3-0.0.1.pom"
            python - <<'PY'
            import os, xml.etree.ElementTree as ET
            root = ET.parse(os.environ['ORIGINAL']).getroot()
            root.find('{*}version').text = '0.0.1'
            ET.ElementTree(root).write(os.environ['TARGET'], encoding='utf-8', xml_declaration=True)
            PY
          '';
    in
    result;
  provider = makeProvider "upickle";
  coreProvider = makeProvider "upickle-core";
  original = builtins.fromJSON (builtins.readFile ./fixtures/simple/mill-purifier.lock.json);
  withoutProvided = removeAttrs (
    original
    // {
      artifacts = builtins.filter (
        entry: !(pkgs.lib.hasInfix "/com/lihaoyi/upickle_3/4.1.0/" entry.path)
      ) original.artifacts;
    }
  ) [ "contentHash" ];
  lockFile = builtins.toFile "mill-purifier.lock.json" (
    builtins.toJSON (
      withoutProvided
      // {
        contentHash = "sha256:${builtins.hashString "sha256" (builtins.toJSON withoutProvided)}";
      }
    )
  );
  consumer = build {
    src = ./fixtures/simple;
    inherit lockFile;
    projectDependencies = [ provider ];
  };
in
pkgs.runCommand "mill-nix-composition"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    passthru = { inherit provider coreProvider consumer; };
  }
  ''
    test -f ${consumer.tests}
    export CATALOG=${provider.projections.maven.catalog}
    export POM=${consumer.packages.core.artifacts."core_3.pom"}
    python - <<'PY'
    import json, os, xml.etree.ElementTree as ET
    catalog = json.load(open(os.environ['CATALOG']))
    selected = next(m['version'] for m in catalog['modules'] if m['name'] == 'upickle_3')
    root = ET.parse(os.environ['POM']).getroot()
    ns = {'m': root.tag.split('}')[0][1:]}
    dependency = next(d for d in root.findall('m:dependencies/m:dependency', ns)
                      if d.findtext('m:artifactId', namespaces=ns) == 'upickle_3')
    assert dependency.findtext('m:version', namespaces=ns) == selected
    PY
    touch $out
  ''
