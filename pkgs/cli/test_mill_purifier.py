# SPDX-License-Identifier: MIT
"""Unit tests of the lock run's parsing and bookkeeping in mill_purifier.py.

Run with `python3 -m unittest test_mill_purifier` from this directory.
"""

import io
import json
import os
import tempfile
import unittest
import zipfile
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

import coursier_cache
import mill_purifier as mp


def write(root, rel, text=""):
    path = Path(root, rel)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


class BuildConfigTest(unittest.TestCase):
    def test_header_of_build_mill(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = write(tmp, "build.mill", "//| mill-version: 1.3.1\n//| mill-jvm-version: system\npackage build\n//| ignored: yes\n")
            self.assertEqual(mp.header_config(f), {"mill-version": "1.3.1", "mill-jvm-version": "system"})

    def test_header_of_build_mill_yaml(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = write(tmp, "build.mill.yaml", "mill-version: '1.3.1'\nmvnDeps:\n  - a:b:1\n")
            self.assertEqual(mp.header_config(f)["mill-version"], "1.3.1")

    def test_settings_files_come_before_the_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, "build.mill", "//| mill-version: 1.0.0\n")
            self.assertEqual(mp.mill_config(root, "mill-version"), "1.0.0")
            write(root, ".config/mill-version", "1.1.0\n")
            self.assertEqual(mp.mill_config(root, "mill-version"), "1.1.0")
            write(root, ".mill-version", "# a comment\n1.2.0\n")
            self.assertEqual(mp.mill_config(root, "mill-version"), "1.2.0")

    def test_no_build_file(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(mp.Failure):
            mp.build_file(Path(tmp))


class DefinitionTest(unittest.TestCase):
    def tree(self, root):
        for rel in [
            "build.mill",
            "core/package.mill",
            "core/src/Main.scala",
            "mill-build/src/Plugin.scala",
            ".mill-jvm-opts",
            ".config/mill-version",
            "out/foo/package.mill",
            "core/.bsp/x.mill",
            ".git/config",
        ]:
            write(root, rel, rel)

    def test_definition_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.tree(tmp)
            self.assertEqual(
                mp.definition_files(Path(tmp)),
                [".config/mill-version", ".mill-jvm-opts", "build.mill", "core/package.mill", "mill-build/src/Plugin.scala"],
            )

    def test_hash_follows_the_definition_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.tree(root)
            first = mp.definition_hash(root)
            self.assertTrue(first.startswith("sha256:"))
            write(root, "core/src/Main.scala", "changed")
            self.assertEqual(mp.definition_hash(root), first)
            write(root, "core/package.mill", "changed")
            self.assertNotEqual(mp.definition_hash(root), first)

    def test_hash_is_the_documented_listing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, "build.mill", "x")
            # sha256("x") = 2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881
            listing = '[["build.mill","2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881"]]'
            import hashlib

            self.assertEqual(mp.definition_hash(root), "sha256:" + hashlib.sha256(listing.encode()).hexdigest())


class PublishedFilesTest(unittest.TestCase):
    def test_artifact_key(self):
        self.assertEqual(mp.artifact_key("core_3-0.1.0-sources.jar", "core_3", "0.1.0"), "core_3-sources.jar")
        self.assertEqual(mp.artifact_key("core_3-0.1.0.pom", "core_3", "0.1.0"), "core_3.pom")
        self.assertEqual(mp.artifact_key("v-1.2.3-5-012345.jar", "v", "1.2.3-5-012345"), "v.jar")

    def test_artifact_key_of_a_foreign_file(self):
        with self.assertRaises(mp.Failure):
            mp.artifact_key("other-0.1.0.jar", "core_3", "0.1.0")

    def test_plus(self):
        self.assertEqual(mp.plus(["a", "b", "c"]), ["a", "+", "b", "+", "c"])
        self.assertEqual(mp.plus([]), [])


INDEX = {
    "zulu": {
        "17.0.19": "tgz+https://cdn.azul.com/zulu/bin/zulu17-linux_x64.tar.gz",
        "25.0.3": "tgz+https://cdn.azul.com/zulu/bin/zulu25-linux_x64.tar.gz",
    }
}
ARM_INDEX = {
    "zulu": {
        "17.0.19": "tgz+https://cdn.azul.com/zulu/bin/zulu17-linux_aarch64.tar.gz",
        "25.0.3": "tgz+https://cdn.azul.com/zulu/bin/zulu25-linux_aarch64.tar.gz",
    }
}


def index_jar(path, platform, index):
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(f"coursier/jvm/indices/v1/{platform}.json", json.dumps(index))


class JvmIndexTest(unittest.TestCase):
    def test_archive_url(self):
        self.assertEqual(mp.archive_url("tgz+https://h/a.tar.gz"), "https://h/a.tar.gz")
        self.assertEqual(mp.archive_url("https://h/a.tar.gz"), "https://h/a.tar.gz")

    def test_jvms_of(self):
        self.assertEqual(
            mp.jvms_of(INDEX, ["https://cdn.azul.com/zulu/bin/zulu25-linux_x64.tar.gz"]), [("zulu", "25.0.3")]
        )
        with self.assertRaises(mp.Failure):
            mp.jvms_of(INDEX, ["https://elsewhere/jdk.tar.gz"])

    def test_nix_system(self):
        with mock.patch("platform.machine", return_value="x86_64"), mock.patch("sys.platform", "linux"):
            self.assertEqual(mp.nix_system(), "x86_64-linux")
        with mock.patch("platform.machine", return_value="arm64"), mock.patch("sys.platform", "darwin"):
            self.assertEqual(mp.nix_system(), "aarch64-darwin")

    def test_lock_platforms(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache, state = Path(tmp, "cache"), Path(tmp, "state")
            own_jar, own_pom = mp.jvm_index_files("linux-amd64", "0.0.4")
            index_jar(cache / own_jar, "linux-amd64", INDEX)
            write(cache, own_pom, "<project/>")
            archive = coursier_cache.cache_path("https://cdn.azul.com/zulu/bin/zulu17-linux_x64.tar.gz")
            write(cache, archive, "x64 jdk")
            other_library = "https/repo1.maven.org/maven2/a/b/1/b-1.jar"
            write(cache, other_library, "jar")

            def fake_download(url, dest):
                dest.parent.mkdir(parents=True, exist_ok=True)
                if url.endswith(".jar"):
                    index_jar(dest, "linux-arm64", ARM_INDEX)
                else:
                    dest.write_text(url)

            with mock.patch.object(mp, "nix_system", return_value="x86_64-linux"), mock.patch.object(
                mp, "download", side_effect=fake_download
            ):
                platforms, specific = mp.lock_platforms([own_jar, own_pom, archive, other_library], [archive], cache, state)

            self.assertEqual(specific, {own_jar, own_pom, archive})
            self.assertEqual(platforms["x86_64-linux"]["archives"], [archive])
            arm = platforms["aarch64-linux"]
            self.assertEqual(arm["archives"], [coursier_cache.cache_path("https://cdn.azul.com/zulu/bin/zulu17-linux_aarch64.tar.gz")])
            self.assertEqual(
                sorted(e["path"] for e in arm["artifacts"]),
                sorted([*mp.jvm_index_files("linux-arm64", "0.0.4"), *arm["archives"]]),
            )
            # Maven Central entries name the mirror.
            index_entry = next(e for e in arm["artifacts"] if e["path"].endswith(".jar"))
            self.assertEqual(index_entry["mirrors"], [mp.MAVEN_CENTRAL_MIRROR + index_entry["url"][len(mp.MAVEN_CENTRAL) :]])

    def test_lock_platforms_without_an_index(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(mp, "nix_system", return_value="x86_64-linux"):
            with self.assertRaises(mp.Failure):
                mp.lock_platforms(["https/cdn.azul.com/jdk.tar.gz"], ["https/cdn.azul.com/jdk.tar.gz"], Path(tmp), Path(tmp))


class MirrorTest(unittest.TestCase):
    def test_canonical_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp)
            mirrored = coursier_cache.cache_path(mp.MAVEN_CENTRAL_MIRROR + "/a/b/1/b-1.jar")
            write(cache, mirrored, "jar")
            with mock.patch.dict(os.environ, {"MILL_PURIFIER_MAVEN_CENTRAL_MIRROR": mp.MAVEN_CENTRAL_MIRROR}):
                mp.canonical_cache(cache)
            self.assertEqual(coursier_cache.downloaded_files(cache), ["https/repo1.maven.org/maven2/a/b/1/b-1.jar"])

    def test_mirror_env(self):
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.dict(os.environ, {"MILL_PURIFIER_MAVEN_CENTRAL_MIRROR": "https://m/maven2/"}):
                env = mp.mirror_env({}, Path(tmp))
            self.assertEqual(env["COURSIER_REPOSITORIES"], "ivy2Local|https://m/maven2")
            self.assertIn("central.to=https://m/maven2", Path(env["COURSIER_MIRRORS"]).read_text())
            with mock.patch.dict(os.environ, {}, clear=True):
                self.assertEqual(mp.mirror_env({"A": "b"}, Path(tmp)), {"A": "b"})


class ReadLockTest(unittest.TestCase):
    def build(self, tmp, lock_text):
        root = Path(tmp)
        write(root, "build.mill", "//| mill-version: 1.3.1\n")
        write(root, mp.LOCK_FILE, lock_text)
        return root

    def test_missing_lockfile(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, "build.mill", "")
            with self.assertRaisesRegex(mp.Failure, "mill-purifier lock"):
                mp.read_lock(root)

    def test_invalid_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(mp.Failure, "not valid JSON.*relock"):
                mp.read_lock(self.build(tmp, "{"))

    def test_not_a_lockfile(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(mp.Failure, "not a mill-purifier lockfile"):
                mp.read_lock(self.build(tmp, '{"version": 1}'))

    def test_other_format_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            text = json.dumps({"version": 0, "launcher": "x", "artifacts": []})
            with self.assertRaisesRegex(mp.Failure, "format version 0"):
                mp.read_lock(self.build(tmp, text))

    def test_stale_lock_warns_with_the_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            text = json.dumps({"version": mp.LOCK_VERSION, "launcher": "x", "artifacts": [], "definitionHash": "sha256:0"})
            err = io.StringIO()
            with redirect_stderr(err):
                mp.read_lock(self.build(tmp, text))
            self.assertIn("run `mill-purifier lock`", err.getvalue())


FAKE_BSP_SERVER = r"""
import json, sys
def read():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline().decode().strip()
        if not line:
            break
        k, _, v = line.partition(":")
        headers[k.strip().lower()] = v.strip()
    return json.loads(sys.stdin.buffer.read(int(headers["content-length"])))
def write(m):
    body = json.dumps(m).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()
while True:
    m = read()
    if m["method"] == "build/exit":
        break
    if "id" in m:
        write({"jsonrpc": "2.0", "method": "build/logMessage", "params": {"message": "working"}})
        write({"jsonrpc": "2.0", "id": m["id"], "result": {"echo": m["method"]}})
"""


class BspTest(unittest.TestCase):
    def test_request_skips_notifications_and_closes(self):
        import sys

        with tempfile.TemporaryDirectory() as tmp:
            bsp = mp.Bsp([sys.executable, "-c", FAKE_BSP_SERVER], tmp, dict(os.environ))
            self.assertEqual(bsp.request("workspace/buildTargets", {}), {"echo": "workspace/buildTargets"})
            self.assertEqual(bsp.request("build/initialize", {}), {"echo": "build/initialize"})
            bsp.close()
            self.assertEqual(bsp.proc.returncode, 0)


class MillExecutableTest(unittest.TestCase):
    def test_script_runs_the_purifier_in_the_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp, "my build")
            root.mkdir()
            env = {"MILL_PURIFIER_BIN": "/nix/store/x/bin/mill-purifier", "XDG_CACHE_HOME": str(Path(tmp, "cache"))}
            with mock.patch.dict(os.environ, env):
                script = mp.mill_executable(root)
            text = script.read_text()
            self.assertIn(f"cd '{root}'", text)
            self.assertIn("exec /nix/store/x/bin/mill-purifier mill \"$@\"", text)
            self.assertTrue(os.access(script, os.X_OK))


if __name__ == "__main__":
    unittest.main()
