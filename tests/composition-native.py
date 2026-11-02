#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise native locking and execution with a Nix-provided JVM module."""
from pathlib import Path
import json, os, shutil, subprocess, tempfile

root = Path(__file__).resolve().parent.parent
system = subprocess.check_output(
    ['nix', 'eval', '--impure', '--raw', '--expr', 'builtins.currentSystem'], text=True).strip()
snapshot = json.loads(subprocess.check_output(
    ['nix', 'flake', 'metadata', '--json', '--no-write-lock-file', 'path:' + str(root)], text=True))['path']
with tempfile.TemporaryDirectory(prefix="purifier-native-composition-") as temporary:
    temporary = Path(temporary)
    package = subprocess.check_output(
        ['nix', 'build', str(root) + '#default', '--print-out-paths',
         '--out-link', str(temporary / 'cli')], text=True).strip().splitlines()[-1]
    cli = Path(package) / 'bin/mill-purifier'
    workspace = temporary / 'project'
    shutil.copytree(root / 'tests/fixtures/simple', workspace)
    (workspace / 'mill-purifier.lock.json').unlink(missing_ok=True)
    definition = workspace / 'build.mill'
    contents = definition.read_text()
    assert 'mvn"com.lihaoyi::upickle:4.1.0"' in contents
    contents = contents.replace('def mvnDeps = Seq(mvn"com.lihaoyi::upickle:4.1.0")',
        'def selectedVersion = "99.0.0"\n  def mvnDeps = Seq(mvn"com.lihaoyi::upickle:${selectedVersion}")')
    definition.write_text(contents)
    reference='path:'+snapshot+'#checks.'+system+'.composition.provider'
    env=dict(os.environ,MILL_PURIFIER_MAVEN_CENTRAL_MIRROR='https://repo.maven.apache.org/maven2')
    def run(*args):
        subprocess.run([str(x) for x in args],cwd=workspace,env=env,check=True)
    run(cli,'lock','--input',reference)
    locked=json.loads((workspace/'mill-purifier.lock.json').read_text())
    assert len(locked['projectInputs'])==1
    assert not any('/com/lihaoyi/upickle_3/99.0.0/' in entry['path'] for entry in locked['artifacts'])
    assert any('/com/lihaoyi/upickle_3/4.4.3/' in entry['path'] for entry in locked['artifacts'])
    run(cli,'prefetch')
    run(cli,'mill','core.test')
    expression = """let
      flake = builtins.getFlake (builtins.getEnv "MILL_COMPOSITION_SOURCE");
      project = builtins.getEnv "MILL_COMPOSITION_PROJECT";
      build = import (flake.outPath + "/nix/lib/cli.nix") {
        nixpkgs = flake.inputs.nixpkgs;
        purifierSource = flake.inputs.purifier;
        src = project;
        lockFile = project + "/mill-purifier.lock.json";
      };
    in build.tests"""
    subprocess.run(['nix', 'build', '--impure', '--expr', expression,
                    '--out-link', str(temporary / 'pure-tests')], check=True,
                   env=dict(env, MILL_COMPOSITION_SOURCE='path:'+snapshot,
                            MILL_COMPOSITION_PROJECT=str(workspace)))
    print('MILL NATIVE AND PURE COMPUTED-VERSION ROUNDTRIP PASSED')
