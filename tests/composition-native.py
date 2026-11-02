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
    reference='path:'+snapshot+'#checks.'+system+'.composition.provider'
    env=dict(os.environ,MILL_PURIFIER_MAVEN_CENTRAL_MIRROR='https://repo.maven.apache.org/maven2')
    def run(*args):
        subprocess.run([str(x) for x in args],cwd=workspace,env=env,check=True)
    run(cli,'lock','--input',reference)
    locked=json.loads((workspace/'mill-purifier.lock.json').read_text())
    assert len(locked['projectInputs'])==1
    assert not any('/com/lihaoyi/upickle_3/4.1.0/' in entry['path'] for entry in locked['artifacts'])
    assert any('/com/lihaoyi/upickle_3/4.4.3/' in entry['path'] for entry in locked['artifacts'])
    run(cli,'prefetch')
    run(cli,'mill','core.test')
    print('MILL NATIVE ROUNDTRIP PASSED')
