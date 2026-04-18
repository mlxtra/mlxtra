#!/usr/bin/env python3
"""Unit tests for python_bridge.py"""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "MLXHub" / "Resources"))
import python_bridge


class TestNormalizeMessages(unittest.TestCase):
    def test_convert_string_args_to_dict(self):
        """String JSON args should become dict"""
        messages = [
            {
                "role": "user",
                "tool_calls": [{"function": {"name": "fn", "arguments": '{"k": "v"}'}}],
            }
        ]
        result = python_bridge._normalize_messages(messages)
        assert isinstance(result[0]["tool_calls"][0]["function"]["arguments"], dict)

    def test_dict_args_unchanged(self):
        messages = [
            {
                "role": "user",
                "tool_calls": [{"function": {"name": "fn", "arguments": {"k": "v"}}}],
            }
        ]
        result = python_bridge._normalize_messages(messages)
        assert isinstance(result[0]["tool_calls"][0]["function"]["arguments"], dict)

    def test_invalid_json_stays_string(self):
        messages = [
            {
                "role": "user",
                "tool_calls": [{"function": {"name": "fn", "arguments": "not json"}}],
            }
        ]
        result = python_bridge._normalize_messages(messages)
        assert result[0]["tool_calls"][0]["function"]["arguments"] == "not json"

    def test_empty_messages(self):
        assert python_bridge._normalize_messages([]) == []


class TestParseToolCalls(unittest.TestCase):
    def test_qwen_tool_call_coerces_music_parameters(self):
        text = """
        <tool_call>
        <function=generate_music>
        <parameter=caption>A mysterious orchestral clockwork garden cue</parameter>
        <parameter=duration>60</parameter>
        <parameter=instrumental>True</parameter>
        </function>
        </tool_call>
        """

        result = python_bridge.parse_tool_calls(text)
        assert len(result) == 1

        args = json.loads(result[0]["function"]["arguments"])
        assert args["caption"] == "A mysterious orchestral clockwork garden cue"
        assert args["duration"] == 60
        assert args["instrumental"] is True


class TestLastUserPrompt(unittest.TestCase):
    def test_returns_last_user_content(self):
        messages = [
            {"role": "system", "content": "You are helpful"},
            {"role": "user", "content": "First question"},
            {"role": "assistant", "content": "Answer"},
            {"role": "user", "content": "Last question"},
        ]
        result = python_bridge._last_user_prompt(messages)
        assert result == "Last question"

    def test_empty_when_no_user(self):
        messages = [{"role": "assistant", "content": "No user here"}]
        assert python_bridge._last_user_prompt(messages) == ""

    def test_handles_empty_list(self):
        assert python_bridge._last_user_prompt([]) == ""

    def test_strips_whitespace(self):
        messages = [{"role": "user", "content": " trimmed "}]
        assert python_bridge._last_user_prompt(messages) == "trimmed"


class TestSendJson(unittest.TestCase):
    def test_outputs_valid_json(self):
        import io
        from contextlib import redirect_stdout

        captured = io.StringIO()
        with redirect_stdout(captured):
            python_bridge.send_json({"type": "test", "data": 123})
        parsed = json.loads(captured.getvalue().strip())
        assert parsed["type"] == "test"
        assert parsed["data"] == 123


class TestLogDebug(unittest.TestCase):
    def test_uses_stderr(self):
        import io
        from contextlib import redirect_stderr

        captured = io.StringIO()
        with redirect_stderr(captured):
            python_bridge.log_debug("test message")
        assert "test message" in captured.getvalue()


class TestModelRegistries(unittest.TestCase):
    def test_registries_initially_empty(self):
        assert python_bridge.MODEL_REGISTRY == {}
        assert python_bridge.IMAGE_MODEL_REGISTRY == {}
        assert python_bridge.AUDIO_MODEL_REGISTRY == {}
        assert python_bridge.MUSIC_MODEL_REGISTRY == {}

    def test_handles_clear(self):
        python_bridge.MODEL_REGISTRY["test"] = "value"
        python_bridge.IMAGE_MODEL_REGISTRY["test"] = "value"
        python_bridge.AUDIO_MODEL_REGISTRY["test"] = "value"
        python_bridge.MUSIC_MODEL_REGISTRY["test"] = "value"
        python_bridge.MODEL_REGISTRY.clear()
        python_bridge.IMAGE_MODEL_REGISTRY.clear()
        python_bridge.AUDIO_MODEL_REGISTRY.clear()
        python_bridge.MUSIC_MODEL_REGISTRY.clear()
        assert python_bridge.MODEL_REGISTRY == {}


class TestImageModelLoading(unittest.TestCase):
    def test_passes_model_path_to_mflux(self):
        from unittest.mock import MagicMock, patch

        model_id = "test-org/test-flux-model"
        mock_model_instance = MagicMock()
        mock_flux_class = MagicMock(return_value=mock_model_instance)

        with patch("mflux.models.flux2.variants.Flux2Klein", mock_flux_class), \
             patch("mflux.models.common.config.ModelConfig.flux2_klein_4b", MagicMock()):
            
            result = python_bridge.load_image_model_if_needed(model_id)

            # Check that Flux2Klein was called with model_path=model_id
            args, kwargs = mock_flux_class.call_args
            assert kwargs["model_path"] == model_id
            assert result == mock_model_instance


if __name__ == "__main__":
    unittest.main()
