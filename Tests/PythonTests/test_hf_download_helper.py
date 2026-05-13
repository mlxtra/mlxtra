import hashlib
import importlib.util
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch


class _DummyTqdm:
    def __init__(self, *args, **kwargs):
        self.total = kwargs.get("total")
        self.n = 0
        self.unit = kwargs.get("unit", "")
        self.desc = kwargs.get("desc", "")

    def update(self, n=1):
        self.n += n

    def close(self):
        return None


def _load_helper():
    sys.modules.setdefault(
        "huggingface_hub",
        types.SimpleNamespace(HfApi=object, snapshot_download=lambda *args, **kwargs: None),
    )

    tqdm_module = types.ModuleType("tqdm")
    tqdm_auto_module = types.ModuleType("tqdm.auto")
    tqdm_auto_module.tqdm = _DummyTqdm
    sys.modules.setdefault("tqdm", tqdm_module)
    sys.modules.setdefault("tqdm.auto", tqdm_auto_module)

    repo_root = Path(__file__).resolve().parents[2]
    helper_path = repo_root / "MLXtra" / "Resources" / "runtime" / "macos-arm64" / "hf_download_helper.py"
    spec = importlib.util.spec_from_file_location("hf_download_helper", helper_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HuggingFaceDownloadHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.helper = _load_helper()

    def test_extracts_stable_lfs_sha256_from_manifest_metadata(self):
        digest = "a" * 64

        self.assertEqual(self.helper.stable_lfs_sha256({"sha256": digest}), digest)
        self.assertEqual(self.helper.stable_lfs_sha256({"oid": digest.upper()}), digest)
        self.assertIsNone(self.helper.stable_lfs_sha256({"oid": "not-a-sha"}))

    def test_verify_snapshot_checks_small_file_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = b"verified content"
            (root / "config.json").write_bytes(payload)

            result = self.helper.verify_snapshot(
                root,
                [
                    {
                        "path": "config.json",
                        "size": len(payload),
                        "sha256": hashlib.sha256(payload).hexdigest(),
                    }
                ],
            )

        self.assertEqual(result["file_count"], 1)
        self.assertEqual(result["hash_count"], 1)
        self.assertEqual(result["hash_skipped"], 0)

    def test_verify_snapshot_reports_hash_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = b"changed content"
            (root / "weights.safetensors").write_bytes(payload)

            with patch.dict(os.environ, {"MLXTRA_HASH_VERIFY_MAX_BYTES": "1024"}):
                with self.assertRaisesRegex(RuntimeError, "hash mismatches"):
                    self.helper.verify_snapshot(
                        root,
                        [
                            {
                                "path": "weights.safetensors",
                                "size": len(payload),
                                "sha256": "0" * 64,
                            }
                        ],
                    )

    def test_verify_snapshot_skips_large_hashes_by_default_threshold(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = b"skip me"
            (root / "large.bin").write_bytes(payload)

            with patch.dict(os.environ, {"MLXTRA_HASH_VERIFY_MAX_BYTES": "0"}):
                result = self.helper.verify_snapshot(
                    root,
                    [
                        {
                            "path": "large.bin",
                            "size": len(payload),
                            "sha256": "0" * 64,
                        }
                    ],
                )

        self.assertEqual(result["hash_count"], 0)
        self.assertEqual(result["hash_skipped"], 1)


if __name__ == "__main__":
    unittest.main()
