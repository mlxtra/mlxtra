#!/usr/bin/env python3
"""Unit tests for magenta_bridge.py."""

import json
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "MLXtra" / "Resources"))

import magenta_bridge


class TestMagentaBridge(unittest.TestCase):
    def test_model_name_accepts_supported_catalog_ids(self):
        self.assertEqual(
            magenta_bridge.model_name("google/magenta-realtime-2/mrt2_small"),
            "mrt2_small",
        )
        self.assertEqual(
            magenta_bridge.model_name("google/magenta-realtime-2/mrt2_base"),
            "mrt2_base",
        )
        self.assertIsNone(magenta_bridge.model_name("google/magenta-realtime-2/unknown"))

    def test_generate_music_once_uses_mlxfn_and_keeps_stdout_json_only(self):
        self.exercise_generation(modern_api=False)

    def test_generate_music_once_uses_203_conditioning_api(self):
        self.exercise_generation(modern_api=True)

    def exercise_generation(self, modern_api):
        captured = {}

        class FakePaths:
            @staticmethod
            def set_magenta_home(path):
                captured["magenta_home"] = Path(path)

        class FakeRandom:
            @staticmethod
            def seed(seed):
                captured["seed"] = seed

        class FakeWaveform:
            def write(self, path):
                print("waveform write noise")
                captured["output_path"] = path

        class FakeGenerator:
            def __init__(self, size, temperature, top_k, cfg_musiccoca, cfg_notes):
                print("generator init noise")
                captured["generator_kwargs"] = dict(size=size, temperature=temperature, top_k=top_k,
                                                    cfg_musiccoca=cfg_musiccoca, cfg_notes=cfg_notes)

            def embed_style(self, prompt, **kwargs):
                print("embed noise")
                captured["prompt"] = prompt
                captured["embed_kwargs"] = kwargs
                return "embedding"

            def generate(self, style, frames):
                print("generate noise")
                captured["generate_kwargs"] = dict(style=style, frames=frames)
                return FakeWaveform(), []

        class ModernGenerator(FakeGenerator):
            def __init__(self, size, temperature, top_k, cfg_scales):
                print("generator init noise")
                captured["generator_kwargs"] = dict(size=size, temperature=temperature, top_k=top_k,
                                                    cfg_scales=cfg_scales)

            def generate(self, conditioning, frames):
                print("generate noise")
                captured["generate_kwargs"] = dict(conditioning=conditioning, frames=frames)
                return FakeWaveform(), []

        mlx_core = types.ModuleType("mlx.core")
        mlx_core.random = FakeRandom()
        mlx_module = types.ModuleType("mlx")
        mlx_module.core = mlx_core
        magenta_rt = types.ModuleType("magenta_rt")
        if modern_api:
            magenta_rt.MagentaRT2StdMlxfn = ModernGenerator
        else:
            magenta_rt.MagentaRT2Mlxfn = FakeGenerator
        magenta_rt.paths = FakePaths()
        magenta_config = types.ModuleType("magenta_rt.config")
        magenta_config.MUSICCOCA = types.SimpleNamespace(key="mulan_tokens_25hz")

        modules = {
            "mlx": mlx_module,
            "mlx.core": mlx_core,
            "magenta_rt": magenta_rt,
            "magenta_rt.config": magenta_config,
        }

        stdout = StringIO()
        stderr = StringIO()
        with tempfile.TemporaryDirectory() as temp_dir:
            checkpoints = Path(temp_dir) / "checkpoints"
            model_home = checkpoints / "magenta-realtime-2" / "mrt2_small"
            (model_home / "models" / "mrt2_small").mkdir(parents=True)

            with patch.dict(sys.modules, modules), patch.dict(
                "os.environ",
                {"MAGENTA_RT_CHECKPOINTS_DIR": str(checkpoints)},
                clear=False,
            ), redirect_stdout(stdout), redirect_stderr(stderr):
                success = magenta_bridge.generate_music_once(
                    {
                        "type": "music.generate",
                        "request_id": "req-magenta",
                        "model": "google/magenta-realtime-2/mrt2_small",
                        "output_dir": temp_dir,
                        "parameters": {
                            "caption": "clockwork garden",
                            "duration": "4",
                            "temperature": "1.1",
                            "top_k": "30",
                            "cfg_musiccoca": "4",
                            "cfg_notes": "0.5",
                            "seed": "0",
                        },
                    }
                )

        self.assertTrue(success)
        messages = [
            json.loads(line)
            for line in stdout.getvalue().splitlines()
            if line.strip()
        ]
        self.assertNotIn("noise", stdout.getvalue())
        self.assertIn("generator init noise", stderr.getvalue())
        self.assertEqual(messages[0]["type"], "model.loading")
        self.assertEqual(messages[-1]["type"], "chat.completion.complete")
        self.assertTrue(all(message["request_id"] == "req-magenta" for message in messages))
        self.assertEqual(captured["magenta_home"], model_home)
        self.assertEqual(captured["seed"], 0)
        self.assertEqual(captured["generator_kwargs"]["size"], "mrt2_small")
        self.assertEqual(captured["embed_kwargs"], {"use_mapper": True, "seed": 0})
        if modern_api:
            self.assertEqual(captured["generator_kwargs"]["cfg_scales"],
                             {"musiccoca": 4.0, "notes": 0.5, "drums": 1.0})
            self.assertEqual(captured["generate_kwargs"]["conditioning"],
                             {"mulan_tokens_25hz": "embedding"})
        else:
            self.assertEqual(captured["generator_kwargs"]["cfg_musiccoca"], 4.0)
            self.assertEqual(captured["generator_kwargs"]["cfg_notes"], 0.5)
            self.assertEqual(captured["generate_kwargs"]["style"], "embedding")
        self.assertEqual(captured["generate_kwargs"]["frames"], 100)


if __name__ == "__main__":
    unittest.main()
