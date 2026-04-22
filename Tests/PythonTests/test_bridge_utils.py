#!/usr/bin/env python3
"""Unit tests for bridge_utils.py"""

import sys
import unittest
from pathlib import Path
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "MLXHub" / "Resources"))
from bridge_utils import log_exception, normalize_music_model_id


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
