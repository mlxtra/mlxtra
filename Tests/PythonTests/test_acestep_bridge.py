#!/usr/bin/env python3
"""Unit tests for acestep_bridge.py"""

import json
import tempfile
import sys
import types
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "MLXtra" / "Resources"))

import acestep_bridge


class TestLastUserPrompt(unittest.TestCase):
    """Tests for last_user_prompt function"""

    def test_returns_last_user_message(self):
        """Should return content from the last user message"""
        messages = [
            {"role": "system", "content": "You are helpful assistant"},
            {"role": "user", "content": "First message"},
            {"role": "assistant", "content": "Response"},
            {"role": "user", "content": "Last user message"},
        ]
        result = acestep_bridge.last_user_prompt(messages)
        self.assertEqual(result, "Last user message")

    def test_returns_empty_when_no_user(self):
        messages = [
            {"role": "system", "content": "System"},
            {"role": "assistant", "content": "Assistant"},
        ]
        result = acestep_bridge.last_user_prompt(messages)
        self.assertEqual(result, "")

    def test_handles_empty_list(self):
        result = acestep_bridge.last_user_prompt([])
        self.assertEqual(result, "")

    def test_strips_whitespace(self):
        messages = [{"role": "user", "content": " Hello world "}]
        result = acestep_bridge.last_user_prompt(messages)
        self.assertEqual(result, "Hello world")

    def test_coerces_non_string_content(self):
        messages = [{"role": "user", "content": 123}]
        result = acestep_bridge.last_user_prompt(messages)
        self.assertEqual(result, "123")


class TestSendJson(unittest.TestCase):
    """Tests for send_json function"""

    def test_send_json_outputs_valid_json(self):
        import io
        from contextlib import redirect_stdout

        captured = io.StringIO()
        with redirect_stdout(captured):
            acestep_bridge.send_json({"type": "test", "data": 123})
        output = captured.getvalue().strip()
        parsed = json.loads(output)
        self.assertEqual(parsed["type"], "test")
        self.assertEqual(parsed["data"], 123)

    def test_send_json_includes_flush(self):
        import io
        from contextlib import redirect_stdout

        captured = io.StringIO()
        with redirect_stdout(captured):
            acestep_bridge.send_json({"type": "model.loaded", "model": "test-model"})
        output = captured.getvalue()
        self.assertIn("model.loaded", output)

    def test_send_json_inherits_request_id(self):
        import io
        from contextlib import redirect_stdout

        captured = io.StringIO()
        with redirect_stdout(captured):
            acestep_bridge.send_json(
                {"type": "model.loaded", "model": "test-model"},
                request={"request_id": "req-123"},
            )
        output = captured.getvalue().strip()
        parsed = json.loads(output)
        self.assertEqual(parsed["request_id"], "req-123")


class TestGenerateMusicOnce(unittest.TestCase):
    def test_coerces_string_bools_and_keeps_stdout_json_only(self):
        captured = {}

        class FakeAceStepHandler:
            def __init__(self):
                print("handler init noise")

            def initialize_service(self, **kwargs):
                print("initialize noise")
                captured["init_kwargs"] = kwargs
                return ("ok", True)

        class FakeLLMHandler:
            def __init__(self):
                print("llm init noise")

        class FakeGenerationParams:
            def __init__(self, **kwargs):
                captured["params_kwargs"] = kwargs

        class FakeGenerationConfig:
            def __init__(self, **kwargs):
                captured["config_kwargs"] = kwargs

        def fake_generate_music(*args, **kwargs):
            print("generate noise")
            captured["generate_kwargs"] = kwargs
            return types.SimpleNamespace(
                success=True,
                audios=[{"path": "/tmp/acestep-test.wav", "sample_rate": 48000}],
            )

        handler_module = types.ModuleType("acestep.handler")
        handler_module.AceStepHandler = FakeAceStepHandler
        inference_module = types.ModuleType("acestep.inference")
        inference_module.GenerationConfig = FakeGenerationConfig
        inference_module.GenerationParams = FakeGenerationParams
        inference_module.generate_music = fake_generate_music
        llm_module = types.ModuleType("acestep.llm_inference")
        llm_module.LLMHandler = FakeLLMHandler
        acestep_module = types.ModuleType("acestep")

        modules = {
            "acestep": acestep_module,
            "acestep.handler": handler_module,
            "acestep.inference": inference_module,
            "acestep.llm_inference": llm_module,
        }

        stdout = StringIO()
        stderr = StringIO()
        with tempfile.TemporaryDirectory() as temp_dir, patch.dict(sys.modules, modules), patch.object(
            acestep_bridge.importlib.util,
            "find_spec",
            return_value=types.SimpleNamespace(origin="/tmp/acestep/__init__.py"),
        ), redirect_stdout(stdout), redirect_stderr(stderr):
            acestep_bridge.generate_music_once(
                {
                    "type": "music.generate",
                    "request_id": "req-music",
                    "model": "ACE-Step/acestep-v15-turbo-continuous",
                    "output_dir": temp_dir,
                    "parameters": {
                        "caption": "clockwork garden",
                        "duration": "12.5",
                        "inference_steps": "4",
                        "thinking": "false",
                        "instrumental": "False",
                        "batch_size": "1",
                        "seed": "42",
                    },
                }
            )

        stdout_lines = [line for line in stdout.getvalue().splitlines() if line.strip()]
        messages = [json.loads(line) for line in stdout_lines]
        self.assertNotIn("noise", stdout.getvalue())
        self.assertIn("initialize noise", stderr.getvalue())
        self.assertEqual(messages[0]["type"], "model.loading")
        self.assertEqual(messages[-1]["type"], "chat.completion.complete")
        self.assertTrue(all(message["request_id"] == "req-music" for message in messages))

        params = captured["params_kwargs"]
        self.assertEqual(params["duration"], 12.5)
        self.assertEqual(params["inference_steps"], 4)
        self.assertFalse(params["thinking"])
        self.assertFalse(params["instrumental"])
        self.assertFalse(params["use_cot_metas"])
        self.assertEqual(params["seed"], 42)


if __name__ == "__main__":
    unittest.main()
