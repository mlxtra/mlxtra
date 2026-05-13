#!/usr/bin/env python3
"""Unit tests for bridge_utils.py"""

import sys
import unittest
from pathlib import Path
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "MLXtra" / "Resources"))
from bridge_utils import (
    build_acestep_generation_inputs,
    coerce_bool,
    coerce_float,
    coerce_int,
    coerce_string,
    log_exception,
    normalize_music_model_id,
)


class TestNormalizeMusicModelId(unittest.TestCase):
    def test_strips_ace_step_prefix_and_continuous_suffix(self):
        self.assertEqual(
            normalize_music_model_id("ACE-Step/acestep-v15-turbo-continuous"),
            "acestep-v15-turbo",
        )

    def test_preserves_non_turbo_models(self):
        self.assertEqual(
            normalize_music_model_id("ACE-Step/acestep-v15-base"),
            "acestep-v15-base",
        )


class TestCoercionHelpers(unittest.TestCase):
    def test_coerce_bool_handles_string_false(self):
        self.assertFalse(coerce_bool("false", True))
        self.assertFalse(coerce_bool("0", True))
        self.assertTrue(coerce_bool("true"))
        self.assertTrue(coerce_bool("1"))

    def test_coerce_bool_uses_default_for_unknown_strings(self):
        self.assertFalse(coerce_bool("maybe"))
        self.assertTrue(coerce_bool("maybe", True))

    def test_coerce_numbers_use_default_for_invalid_values(self):
        self.assertEqual(coerce_int("12", 0), 12)
        self.assertEqual(coerce_int("12.9", 0), 12)
        self.assertEqual(coerce_int("bad", 7), 7)
        self.assertEqual(coerce_float("3.5", 0.0), 3.5)
        self.assertEqual(coerce_float("", 2.0), 2.0)

    def test_coerce_string_handles_non_strings(self):
        self.assertEqual(coerce_string(123), "123")
        self.assertEqual(coerce_string(None, "fallback"), "fallback")


class TestBuildAceStepGenerationInputs(unittest.TestCase):
    def test_builds_generation_and_config_kwargs(self):
        seed, generation_kwargs, config_kwargs = build_acestep_generation_inputs(
            {
                "duration": "12.5",
                "inference_steps": "4",
                "shift": "2.5",
                "thinking": "true",
                "instrumental": "false",
                "bpm": "120",
                "keyscale": "C major",
                "timesignature": "4/4",
                "vocal_language": "en",
                "batch_size": "2",
                "audio_format": "mp3",
            },
            prompt="ambient pop",
            lyrics="hello",
            seed_default=42,
        )

        self.assertEqual(seed, 42)
        self.assertEqual(generation_kwargs["caption"], "ambient pop")
        self.assertEqual(generation_kwargs["lyrics"], "hello")
        self.assertEqual(generation_kwargs["duration"], 12.5)
        self.assertEqual(generation_kwargs["inference_steps"], 4)
        self.assertTrue(generation_kwargs["thinking"])
        self.assertFalse(generation_kwargs["instrumental"])
        self.assertEqual(generation_kwargs["bpm"], 120)
        self.assertEqual(generation_kwargs["keyscale"], "C major")
        self.assertEqual(generation_kwargs["timesignature"], "4/4")
        self.assertEqual(generation_kwargs["vocal_language"], "en")
        self.assertEqual(config_kwargs["batch_size"], 2)
        self.assertEqual(config_kwargs["audio_format"], "mp3")
        self.assertEqual(config_kwargs["seeds"], [42])
        self.assertFalse(config_kwargs["use_random_seed"])

    def test_omits_empty_optional_fields(self):
        _, generation_kwargs, _ = build_acestep_generation_inputs(
            {
                "bpm": 0,
                "keyscale": "",
                "timesignature": "",
                "vocal_language": "unknown",
            },
            prompt="prompt",
            lyrics="",
            seed_default=7,
        )

        self.assertNotIn("bpm", generation_kwargs)
        self.assertNotIn("keyscale", generation_kwargs)
        self.assertNotIn("timesignature", generation_kwargs)
        self.assertNotIn("vocal_language", generation_kwargs)


class TestLogException(unittest.TestCase):
    def test_returns_clean_message_and_logs_context(self):
        logger = Mock()

        try:
            raise ValueError("bad input")
        except ValueError as exc:
            message = log_exception("load failed", exc, logger=logger)

        self.assertEqual(message, "bad input")
        self.assertEqual(logger.call_args_list[0].args[0], "load failed: bad input")
        self.assertIn("ValueError: bad input", logger.call_args_list[1].args[0])


if __name__ == "__main__":
    unittest.main()
