#!/usr/bin/env python3
"""Unit tests for acestep_bridge.py"""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "MLXHub" / "Resources"))

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


if __name__ == "__main__":
    unittest.main()
