# SPDX-License-Identifier: MIT
"""Unit tests of the lock run's parsing and bookkeeping in mill_purifier.py.

Run with `python3 -m unittest test_mill_purifier` from this directory.
"""

import hashlib
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
            # The systems come in alphabetical order, whichever system ran the lock.
            self.assertEqual(list(platforms), ["aarch64-linux", "x86_64-linux"])
            self.assertEqual(sorted(e["path"] for e in platforms["x86_64-linux"]["artifacts"]), sorted([own_jar, own_pom, archive]))
            arm = platforms["aarch64-linux"]
            arm_archive = coursier_cache.cache_path("https://cdn.azul.com/zulu/bin/zulu17-linux_aarch64.tar.gz")
            self.assertEqual(
                sorted(e["path"] for e in arm["artifacts"]),
                sorted([*mp.jvm_index_files("linux-arm64", "0.0.4"), arm_archive]),
            )
            # An entry records only what the lock run observed; Nix derives
            # the URL and the mirrors from the path.
            self.assertEqual({tuple(sorted(e)) for e in arm["artifacts"]}, {("hash", "path")})

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


def sealed(lock_data):
    """A lockfile with the content hash `mill-purifier lock` writes."""
    return json.dumps({**lock_data, "contentHash": mp.content_hash(lock_data)})


class ReadLockTest(unittest.TestCase):
    def build(self, tmp, lock_text):
        root = Path(tmp)
        write(root, "build.mill", "//| mill-version: 1.3.1\n")
        write(root, mp.LOCK_FILE, lock_text)
        return root

    def read(self, root):
        return mp.read_lock(root, root / mp.LOCK_FILE)

    def test_missing_lockfile(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, "build.mill", "")
            with self.assertRaisesRegex(mp.Failure, "mill-purifier lock"):
                self.read(root)

    def test_invalid_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(mp.Failure, "not valid JSON.*mill-purifier lock"):
                self.read(self.build(tmp, "{"))

    def test_not_a_lockfile(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(mp.Failure, "not a mill-purifier lockfile"):
                self.read(self.build(tmp, '{"version": 2}'))

    def test_other_format_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            text = sealed({"version": 0, "definitionHash": "x", "artifacts": []})
            with self.assertRaisesRegex(mp.Failure, "format version 0"):
                self.read(self.build(tmp, text))

    def test_tampered_lockfile(self):
        with tempfile.TemporaryDirectory() as tmp:
            lock_data = json.loads(sealed({"version": mp.LOCK_VERSION, "definitionHash": "x", "artifacts": []}))
            lock_data["artifacts"] = [{"path": "a", "url": "https://a", "mirrors": [], "hash": "sha256-x"}]
            with self.assertRaisesRegex(mp.Failure, "contentHash.*mill-purifier lock"):
                self.read(self.build(tmp, json.dumps(lock_data)))

    def test_stale_lock_warns_with_the_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            text = sealed({"version": mp.LOCK_VERSION, "artifacts": [], "definitionHash": "sha256:0"})
            err = io.StringIO()
            with redirect_stderr(err):
                self.read(self.build(tmp, text))
            self.assertIn("run `mill-purifier lock`", err.getvalue())

    def test_lockfile_outside_the_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp, "build")
            write(root, "build.mill", "")
            outside = write(tmp, "locks/mill-purifier.lock.json", sealed({"version": mp.LOCK_VERSION, "definitionHash": "x", "artifacts": []}))
            with redirect_stderr(io.StringIO()):
                self.assertEqual(mp.read_lock(root, outside)["definitionHash"], "x")


class ContentHashTest(unittest.TestCase):
    def test_matches_the_nix_listing(self):
        # builtins.toJSON writes sorted keys with no spaces.
        listing = '{"a":[1,{"b":"é"}],"version":2}'
        import hashlib

        expected = "sha256:" + hashlib.sha256(listing.encode()).hexdigest()
        self.assertEqual(mp.content_hash({"version": 2, "a": [1, {"b": "é"}], "contentHash": "old"}), expected)


class PrefetchStateTest(unittest.TestCase):
    def test_prefetched_needs_the_same_lockfile_and_store_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            store = Path(tmp, "store")
            (store / "deps").mkdir(parents=True)
            (store / "archives").mkdir()
            state = {"contentHash": "sha256:1", "dependencies": str(store / "deps"), "archiveCache": str(store / "archives")}
            write(root, "locks/.mill-purifier/prefetch.json", json.dumps(state))
            lock_file = root / "locks" / mp.LOCK_FILE
            self.assertEqual(mp.prefetched(lock_file, {"contentHash": "sha256:1"})["dependencies"], str(store / "deps"))
            self.assertIsNone(mp.prefetched(lock_file, {"contentHash": "sha256:2"}))
            (store / "archives").rmdir()
            self.assertIsNone(mp.prefetched(lock_file, {"contentHash": "sha256:1"}))


class MillVersionTest(unittest.TestCase):
    def test_the_first_release_with_the_maven_publisher_is_1_1_0(self):
        for version in ("1.0.0", "1.0.6", "1.1.0-RC1", "1.1.0-RC4", "0.12.14"):
            self.assertLess(mp.mill_version_key(version), mp.MIN_PUBLISHER_MILL_VERSION, version)
        for version in ("1.1.0", "1.1.1", "1.3.1", "2.0.0", "1.2.0-RC1"):
            self.assertGreaterEqual(mp.mill_version_key(version), mp.MIN_PUBLISHER_MILL_VERSION, version)

    def test_mill_1_starts_at_1_0_0(self):
        self.assertLess(mp.mill_version_key("0.12.14"), mp.FIRST_MILL_1)
        self.assertGreaterEqual(mp.mill_version_key("1.0.0"), mp.FIRST_MILL_1)

    def test_lock_refuses_mill_0_before_running_anything(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, "build.mill", "//| mill-version: 0.12.14\npackage build\n")
            with self.assertRaisesRegex(mp.Failure, "Mill 0.12.14.*1.0.0 and later"):
                mp.lock(root, root / mp.LOCK_FILE)


class MillEnvTest(unittest.TestCase):
    USER = {
        "HOME": "/home/user",
        "XDG_CACHE_HOME": "/home/user/.local/cache",
        "XDG_DATA_HOME": "/home/user/.local/data",
        "XDG_DATA_DIRS": "/usr/share",
        "XDG_CONFIG_DIRS": "/etc/xdg",
        "PATH": "/usr/bin",
    }

    def env(self, home):
        with mock.patch.dict(os.environ, self.USER, clear=True), mock.patch.object(mp, "jdk_home", return_value=Path("/jdk")):
            return mp.mill_env(Path("/c"), Path("/a"), home, Path("/t"), offline=True)[0]

    def test_a_lock_run_takes_home_and_the_xdg_directories_from_its_home(self):
        env = self.env(Path("/lock-home"))
        self.assertEqual(env["HOME"], "/lock-home")
        self.assertEqual(env["XDG_CACHE_HOME"], "/lock-home/.cache")
        self.assertEqual(env["XDG_DATA_HOME"], "/lock-home/.local/share")
        self.assertNotIn("XDG_DATA_DIRS", env)
        self.assertNotIn("XDG_CONFIG_DIRS", env)

    def test_the_everyday_loop_keeps_the_environment_of_the_user(self):
        env = self.env(None)
        self.assertEqual({k: env[k] for k in self.USER if k != "PATH"}, {k: v for k, v in self.USER.items() if k != "PATH"})


class SeedListingsTest(unittest.TestCase):
    LISTING = "https/repo1.maven.org/maven2/com/lihaoyi/sourcecode_3/maven-metadata.xml"
    OTHER = "https/repo1.maven.org/maven2/org/scalameta/munit_3/maven-metadata.xml"
    LOCK = {
        "artifacts": [
            {"path": LISTING, "contents": "<metadata>sourcecode</metadata>"},
            {"path": OTHER, "contents": "<metadata>munit</metadata>"},
            {"path": "https/repo1.maven.org/maven2/a/b/1/b-1.jar", "hash": "sha256-x"},
        ]
    }

    def seeded(self, updated, mirror=None):
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp)
            with mock.patch.dict(os.environ, {"MILL_PURIFIER_MAVEN_CENTRAL_MIRROR": mirror or ""}), redirect_stderr(io.StringIO()):
                mp.seed_listings(cache, self.LOCK, updated)
            return {p: (cache / p).read_text() for p in coursier_cache.downloaded_files(cache)}, sorted(
                p.name for p in cache.rglob(".*.checked")
            )

    def test_lock_places_every_recorded_listing_as_fresh(self):
        files, markers = self.seeded(None)
        self.assertEqual(files, {self.LISTING: "<metadata>sourcecode</metadata>", self.OTHER: "<metadata>munit</metadata>"})
        self.assertEqual(markers, [".maven-metadata.xml.checked"] * 2 + [".maven-metadata.xml.sha1.checked"] * 2)

    def test_the_cache_holds_a_checksum_of_the_placed_listing(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp)
            with mock.patch.dict(os.environ, {"MILL_PURIFIER_MAVEN_CENTRAL_MIRROR": ""}):
                mp.seed_listings(cache, self.LOCK, None)
            checksum = (cache / (self.LISTING + ".sha1")).read_text().strip()
            self.assertEqual(checksum, hashlib.sha1(b"<metadata>sourcecode</metadata>").hexdigest())

    def test_update_of_everything_places_none(self):
        self.assertEqual(self.seeded([])[0], {})

    def test_update_of_a_module_leaves_out_its_listing(self):
        self.assertEqual(list(self.seeded(["com.lihaoyi:sourcecode_3"])[0]), [self.OTHER])

    def test_listings_go_where_the_mirror_puts_them(self):
        mirror = "https://mirror.example/maven2"
        files, _ = self.seeded(None, mirror)
        self.assertIn("https/mirror.example/maven2/com/lihaoyi/sourcecode_3/maven-metadata.xml", files)


class LockfileOptionTest(unittest.TestCase):
    def test_the_environment_names_the_lockfile_and_the_option_wins(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, "build.mill", "//| mill-version: 1.3.1\n")
            seen = []
            with mock.patch.object(mp, "lock", side_effect=lambda r, f, **kw: seen.append((f, kw))), mock.patch.object(
                Path, "cwd", return_value=root
            ), mock.patch.dict(os.environ, {"MILL_PURIFIER_LOCKFILE": str(root / "a.json")}):
                mp.main(["lock"])
                mp.main(["update", "--lockfile", str(root / "b.json"), "com.lihaoyi:sourcecode_3"])
                self.assertEqual(mp.main(["update", "sourcecode"]), 2)
            self.assertEqual(
                seen,
                [(root / "a.json", {"tests": None}), (root / "b.json", {"updated": ["com.lihaoyi:sourcecode_3"]})],
            )


class RunWatchingTest(unittest.TestCase):
    def test_names_the_lock_command_after_a_resolution_failure(self):
        import sys

        cmd = [sys.executable, "-c", "import sys; print('Resolution failed for 1 modules', file=sys.stderr); sys.exit(1)"]
        err = io.BytesIO()
        fake_stderr = mock.Mock(buffer=err)
        with mock.patch("sys.stdout.isatty", return_value=False), mock.patch.object(mp.sys, "stderr", fake_stderr):
            code = mp.run_watching(cmd, dict(os.environ))
        self.assertEqual(code, 1)
        self.assertIn(b"Resolution failed", err.getvalue())
        fake_stderr.write.assert_called()
        self.assertIn("mill-purifier lock", "".join(c.args[0] for c in fake_stderr.write.call_args_list))


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
