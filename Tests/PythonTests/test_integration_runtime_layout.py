#!/usr/bin/env python3
"""Tests for split integration runtime resolution."""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

INTEGRATION_TESTS = Path(__file__).resolve().parents[1] / "IntegrationTests"
if str(INTEGRATION_TESTS) not in sys.path:
    sys.path.insert(0, str(INTEGRATION_TESTS))

from runtime_layout import (
    prepared_music_runtime,
    resolve_base_runtime,
    resolve_music_runtime,
)


def touch(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("test\n", encoding="utf-8")


class IntegrationRuntimeLayoutTests(unittest.TestCase):
    def test_resolves_split_bundled_runtimes(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(
            os.environ, {}, clear=True
        ):
            root = Path(directory)
            resources = root / "Resources"
            app_support = root / "Application Support/MLXtra"
            base = resources / "runtime/macos-arm64"
            music = resources / "runtime/music-macos-arm64"

            for relative_path in (
                "venv/bin/python",
                "python/Frameworks/Versions/3.12/lib/libpython.dylib",
                "runtime-manifest.json",
            ):
                touch(base / relative_path)
            for relative_path in (
                "acestep-venv/bin/python",
                "acestep_download_helper.py",
                "runtime-music-manifest.json",
            ):
                touch(music / relative_path)

            self.assertEqual(resolve_base_runtime(resources, app_support), base)
            self.assertEqual(resolve_music_runtime(base, resources), music)

    def test_prepared_music_runtime_cleans_created_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = root / "base"
            music = root / "music"
            (base / "python").mkdir(parents=True)
            (base / "shared").mkdir()
            music.mkdir()

            with prepared_music_runtime(base, music):
                self.assertTrue((music / "python").is_symlink())
                self.assertTrue((music / "shared").is_symlink())

            self.assertFalse((music / "python").exists())
            self.assertFalse((music / "shared").exists())


if __name__ == "__main__":
    unittest.main()
