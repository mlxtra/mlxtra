#!/usr/bin/env python3
"""Unit tests for python_bridge.py"""

import builtins
import json
import io
import os
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "MLXtra" / "Resources"))
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

    def test_system_messages_are_merged_at_beginning(self):
        messages = [
            {"role": "system", "content": "Base instructions"},
            {"role": "user", "content": "Create music"},
            {"role": "assistant", "content": "Do you want vocals?"},
            {"role": "system", "content": "Music is ready"},
            {"role": "user", "content": "Instrumental"},
        ]

        result = python_bridge._normalize_messages(messages)

        assert result[0] == {
            "role": "system",
            "content": "Base instructions\n\nMusic is ready",
        }
        assert [message["role"] for message in result] == [
            "system",
            "user",
            "assistant",
            "user",
        ]


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

    def test_gemma_tool_call_coerces_music_parameters(self):
        text = '<|tool_call|>call:generate_music(caption: "clockwork garden", duration: 60, instrumental: true)<|tool_call|>'

        result = python_bridge.parse_tool_calls(text)
        assert len(result) == 1

        args = json.loads(result[0]["function"]["arguments"])
        assert args["caption"] == "clockwork garden"
        assert args["duration"] == 60
        assert args["instrumental"] is True

    def test_gemma_tool_call_handles_braces_and_quote_tokens(self):
        text = '<|tool_call>call:web_search{query:<|"|>TSLA stock price now<|"|>}<tool_call|>'

        result = python_bridge.parse_tool_calls(text)
        assert len(result) == 1
        assert result[0]["function"]["name"] == "web_search"

        args = json.loads(result[0]["function"]["arguments"])
        assert args["query"] == "TSLA stock price now"

    def test_plain_json_name_parameters_tool_call(self):
        text = '{"name": "web_search", "parameters": {"query": "latest Swift release"}}'

        result = python_bridge.parse_tool_calls(text)
        assert len(result) == 1
        assert result[0]["function"]["name"] == "web_search"

        args = json.loads(result[0]["function"]["arguments"])
        assert args["query"] == "latest Swift release"

    def test_openai_json_tool_calls_shape(self):
        text = json.dumps({
            "tool_calls": [
                {
                    "type": "function",
                    "function": {
                        "name": "generate_music",
                        "arguments": json.dumps({
                            "caption": "clockwork garden",
                            "instrumental": True,
                        }),
                    },
                }
            ]
        })

        result = python_bridge.parse_tool_calls(text)
        assert len(result) == 1
        assert result[0]["function"]["name"] == "generate_music"

        args = json.loads(result[0]["function"]["arguments"])
        assert args["caption"] == "clockwork garden"
        assert args["instrumental"] is True

    def test_plain_json_without_tool_name_is_not_a_tool_call(self):
        text = '{"answer": "No tool needed"}'

        assert python_bridge.parse_tool_calls(text) == []


class TestChatCompletionPerformance(unittest.TestCase):
    def test_response_format_schema_extracts_openai_json_schema(self):
        schema = {
            "type": "object",
            "properties": {"prompt": {"type": "string"}},
            "required": ["prompt"],
        }

        result = python_bridge._response_format_schema(
            {
                "response_format": {
                    "type": "json_schema",
                    "json_schema": {
                        "name": "image_prompt",
                        "schema": schema,
                    },
                }
            }
        )

        self.assertEqual(result, schema)

    def test_chat_completion_uses_generic_structured_output_processor(self):
        schema = {
            "type": "object",
            "properties": {"prompt": {"type": "string"}},
            "required": ["prompt"],
        }
        tokenizer = object()
        processor = types.SimpleNamespace(tokenizer=tokenizer)
        observed = {}

        def fake_load_model_if_needed(model_id, request=None):
            return ("model", processor, {"model_type": "fake"})

        def fake_apply_chat_template(processor, config, messages, num_images=0, **kwargs):
            return "prompt"

        def fake_build_json_schema_logits_processor(received_tokenizer, received_schema):
            observed["tokenizer"] = received_tokenizer
            observed["schema"] = received_schema
            return "structured-processor"

        def fake_stream_generate(*args, **kwargs):
            observed["generation_kwargs"] = kwargs
            yield types.SimpleNamespace(
                text='{"prompt":"A detailed image prompt"}',
                prompt_tokens=7,
                generation_tokens=8,
                prompt_tps=None,
                generation_tps=None,
                peak_memory=None,
            )

        mlx_vlm_module = types.ModuleType("mlx_vlm")
        mlx_vlm_module.stream_generate = fake_stream_generate
        prompt_utils_module = types.ModuleType("mlx_vlm.prompt_utils")
        prompt_utils_module.apply_chat_template = fake_apply_chat_template
        structured_module = types.ModuleType("mlx_vlm.structured")
        structured_module.build_json_schema_logits_processor = (
            fake_build_json_schema_logits_processor
        )
        mlx_module = types.ModuleType("mlx")
        mlx_core_module = types.ModuleType("mlx.core")
        mlx_core_module.clear_cache = lambda: None
        mlx_module.core = mlx_core_module

        request = {
            "type": "chat.completions",
            "model": "fake-model",
            "messages": [{"role": "user", "content": "Improve this prompt"}],
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "image_prompt",
                    "schema": schema,
                },
            },
            "parameters": {
                "runtimeOptions": {
                    "acceleration": {
                        "draftModel": "fake-drafter",
                    }
                }
            },
            "request_id": "req-structured-output",
        }

        with patch.dict(
            sys.modules,
            {
                "mlx": mlx_module,
                "mlx.core": mlx_core_module,
                "mlx_vlm": mlx_vlm_module,
                "mlx_vlm.prompt_utils": prompt_utils_module,
                "mlx_vlm.structured": structured_module,
            },
        ), patch.object(
            python_bridge, "load_model_if_needed", fake_load_model_if_needed
        ), patch.object(
            python_bridge, "_load_drafter_if_requested"
        ) as load_drafter, patch("sys.stdout", new_callable=io.StringIO) as captured:
            python_bridge.handle_chat_completion(request)

        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]
        generation_kwargs = observed["generation_kwargs"]

        self.assertIs(observed["tokenizer"], tokenizer)
        self.assertEqual(observed["schema"], schema)
        self.assertEqual(generation_kwargs["logits_processors"], ["structured-processor"])
        self.assertNotIn("draft_model", generation_kwargs)
        load_drafter.assert_not_called()
        self.assertEqual(messages[-1]["type"], "chat.completion.complete")

    def test_chat_completion_reports_import_failure_as_json_error(self):
        original_import = builtins.__import__

        def import_without_mlx_vlm(name, *args, **kwargs):
            if name == "mlx_vlm" or name.startswith("mlx_vlm."):
                raise ModuleNotFoundError("No module named 'mlx_vlm'")
            return original_import(name, *args, **kwargs)

        request = {
            "type": "chat.completions",
            "model": "fake-model",
            "messages": [{"role": "user", "content": "hello"}],
            "request_id": "req-chat-import-error",
        }

        with patch.object(
            builtins, "__import__", side_effect=import_without_mlx_vlm
        ), patch("sys.stdout", new_callable=io.StringIO) as captured:
            python_bridge.handle_chat_completion(request)

        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]

        self.assertEqual(messages[-1]["type"], "error")
        self.assertEqual(messages[-1]["request_id"], "req-chat-import-error")
        self.assertIn("mlx_vlm", messages[-1]["message"])

    def test_thinking_mode_does_not_emit_synthetic_tool_call_prefix(self):
        def fake_load_model_if_needed(model_id, request=None):
            return ("model", object(), {"model_type": "fake"})

        def fake_apply_chat_template(processor, config, messages, num_images=0, **kwargs):
            self.assertTrue(kwargs["enable_thinking"])
            return "prompt"

        def fake_stream_generate(*args, **kwargs):
            yield types.SimpleNamespace(
                text="A",
                prompt_tokens=7,
                generation_tokens=1,
                prompt_tps=None,
                generation_tps=None,
                peak_memory=None,
            )

        mlx_vlm_module = types.ModuleType("mlx_vlm")
        mlx_vlm_module.stream_generate = fake_stream_generate
        prompt_utils_module = types.ModuleType("mlx_vlm.prompt_utils")
        prompt_utils_module.apply_chat_template = fake_apply_chat_template
        mlx_module = types.ModuleType("mlx")
        mlx_core_module = types.ModuleType("mlx.core")
        mlx_core_module.clear_cache = lambda: None
        mlx_module.core = mlx_core_module

        request = {
            "type": "chat.completions",
            "model": "fake-model",
            "messages": [{"role": "user", "content": "hello"}],
            "chat_template_kwargs": {"enable_thinking": True},
            "request_id": "req-thinking",
        }

        with patch.dict(
            sys.modules,
            {
                "mlx": mlx_module,
                "mlx.core": mlx_core_module,
                "mlx_vlm": mlx_vlm_module,
                "mlx_vlm.prompt_utils": prompt_utils_module,
            },
        ), patch.object(
            python_bridge, "load_model_if_needed", fake_load_model_if_needed
        ), patch("sys.stdout", new_callable=io.StringIO) as captured:
            python_bridge.handle_chat_completion(request)

        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]

        chunks = [
            message["choices"][0]["delta"]["content"]
            for message in messages
            if message.get("type") == "chat.completion.chunk"
        ]
        complete = messages[-1]

        self.assertEqual(chunks, ["A"])
        self.assertEqual(complete["choices"][0]["message"]["content"], "A")
        self.assertNotIn("<tool_call>", "".join(chunks))

    def test_chat_completion_passes_drafter_to_stream_generate(self):
        python_bridge.DRAFTER_MODEL_REGISTRY.clear()
        observed_kwargs = {}

        def fake_load_model_if_needed(model_id, request=None):
            return ("model", object(), {"model_type": "fake"})

        def fake_apply_chat_template(processor, config, messages, num_images=0, **kwargs):
            return "prompt"

        def fake_stream_generate(*args, **kwargs):
            observed_kwargs.update(kwargs)
            yield types.SimpleNamespace(
                text="A",
                prompt_tokens=7,
                generation_tokens=1,
                prompt_tps=None,
                generation_tps=None,
                peak_memory=None,
            )

        mlx_vlm_module = types.ModuleType("mlx_vlm")
        mlx_vlm_module.__path__ = []
        mlx_vlm_module.stream_generate = fake_stream_generate
        prompt_utils_module = types.ModuleType("mlx_vlm.prompt_utils")
        prompt_utils_module.apply_chat_template = fake_apply_chat_template
        speculative_module = types.ModuleType("mlx_vlm.speculative")
        speculative_module.__path__ = []
        drafters_module = types.ModuleType("mlx_vlm.speculative.drafters")
        drafters_module.load_drafter = MagicMock(return_value=("drafter-model", "mtp"))
        speculative_module.drafters = drafters_module
        mlx_vlm_module.speculative = speculative_module
        mlx_module = types.ModuleType("mlx")
        mlx_core_module = types.ModuleType("mlx.core")
        mlx_core_module.clear_cache = lambda: None
        mlx_module.core = mlx_core_module

        request = {
            "type": "chat.completions",
            "model": "fake-model",
            "messages": [{"role": "user", "content": "hello"}],
            "request_id": "req-drafter",
            "parameters": {
                "runtimeOptions": {
                    "acceleration": {
                        "draftModel": "/tmp/drafter",
                        "draftBlockSize": 4,
                    }
                }
            },
        }

        with patch.dict(
            sys.modules,
            {
                "mlx": mlx_module,
                "mlx.core": mlx_core_module,
                "mlx_vlm": mlx_vlm_module,
                "mlx_vlm.prompt_utils": prompt_utils_module,
                "mlx_vlm.speculative": speculative_module,
                "mlx_vlm.speculative.drafters": drafters_module,
            },
        ), patch.object(
            python_bridge, "load_model_if_needed", fake_load_model_if_needed
        ), patch("sys.stdout", new_callable=io.StringIO) as captured:
            python_bridge.handle_chat_completion(request)

        drafters_module.load_drafter.assert_called_once_with("/tmp/drafter", kind=None)
        self.assertEqual(observed_kwargs["draft_model"], "drafter-model")
        self.assertEqual(observed_kwargs["draft_kind"], "mtp")
        self.assertEqual(observed_kwargs["draft_block_size"], 4)

        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]
        self.assertTrue(any(message.get("status") == "acceleration_ready" for message in messages))
        self.assertEqual(messages[-1]["type"], "chat.completion.complete")
        self.assertEqual(
            messages[-1]["acceleration"],
            {
                "requested": True,
                "active": True,
                "state": "active",
                "draft_kind": "mtp",
            },
        )

    def test_chat_completion_falls_back_when_drafter_generation_fails(self):
        python_bridge.DRAFTER_MODEL_REGISTRY.clear()
        generation_attempts = []

        def fake_load_model_if_needed(model_id, request=None):
            return ("model", object(), {"model_type": "fake"})

        def fake_apply_chat_template(processor, config, messages, num_images=0, **kwargs):
            return "prompt"

        def fake_stream_generate(*args, **kwargs):
            if "draft_model" in kwargs:
                generation_attempts.append("draft")
                raise RuntimeError("drafter rejected")
                yield
            generation_attempts.append("base")
            yield types.SimpleNamespace(
                text="B",
                prompt_tokens=7,
                generation_tokens=1,
                prompt_tps=None,
                generation_tps=None,
                peak_memory=None,
            )

        mlx_vlm_module = types.ModuleType("mlx_vlm")
        mlx_vlm_module.__path__ = []
        mlx_vlm_module.stream_generate = fake_stream_generate
        prompt_utils_module = types.ModuleType("mlx_vlm.prompt_utils")
        prompt_utils_module.apply_chat_template = fake_apply_chat_template
        speculative_module = types.ModuleType("mlx_vlm.speculative")
        speculative_module.__path__ = []
        drafters_module = types.ModuleType("mlx_vlm.speculative.drafters")
        drafters_module.load_drafter = MagicMock(return_value=("drafter-model", "mtp"))
        speculative_module.drafters = drafters_module
        mlx_vlm_module.speculative = speculative_module
        mlx_module = types.ModuleType("mlx")
        mlx_core_module = types.ModuleType("mlx.core")
        mlx_core_module.clear_cache = lambda: None
        mlx_module.core = mlx_core_module

        request = {
            "type": "chat.completions",
            "model": "fake-model",
            "messages": [{"role": "user", "content": "hello"}],
            "request_id": "req-drafter-fallback",
            "parameters": {
                "runtimeOptions": {
                    "acceleration": {
                        "draftModel": "/tmp/drafter",
                    }
                }
            },
        }

        with patch.dict(
            sys.modules,
            {
                "mlx": mlx_module,
                "mlx.core": mlx_core_module,
                "mlx_vlm": mlx_vlm_module,
                "mlx_vlm.prompt_utils": prompt_utils_module,
                "mlx_vlm.speculative": speculative_module,
                "mlx_vlm.speculative.drafters": drafters_module,
            },
        ), patch.object(
            python_bridge, "load_model_if_needed", fake_load_model_if_needed
        ), patch("sys.stdout", new_callable=io.StringIO) as captured:
            python_bridge.handle_chat_completion(request)

        self.assertEqual(generation_attempts, ["draft", "base"])
        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]
        self.assertTrue(any(message.get("status") == "acceleration_unavailable" for message in messages))
        complete = messages[-1]
        self.assertEqual(complete["type"], "chat.completion.complete")
        self.assertEqual(complete["choices"][0]["message"]["content"], "B")
        self.assertEqual(
            complete["acceleration"],
            {
                "requested": True,
                "active": False,
                "state": "fallback",
            },
        )

    def test_chat_completion_clears_mlx_cache_after_stream_error(self):
        def fake_load_model_if_needed(model_id, request=None):
            return ("model", object(), {"model_type": "fake"})

        def fake_apply_chat_template(processor, config, messages, num_images=0, **kwargs):
            return "prompt"

        def fake_stream_generate(*args, **kwargs):
            raise RuntimeError("generation failed")
            yield

        mlx_vlm_module = types.ModuleType("mlx_vlm")
        mlx_vlm_module.stream_generate = fake_stream_generate
        prompt_utils_module = types.ModuleType("mlx_vlm.prompt_utils")
        prompt_utils_module.apply_chat_template = fake_apply_chat_template
        mlx_module = types.ModuleType("mlx")
        mlx_core_module = types.ModuleType("mlx.core")
        mlx_core_module.clear_cache = MagicMock()
        mlx_module.core = mlx_core_module

        request = {
            "type": "chat.completions",
            "model": "fake-model",
            "messages": [{"role": "user", "content": "hello"}],
            "request_id": "req-error",
        }

        with patch.dict(
            sys.modules,
            {
                "mlx": mlx_module,
                "mlx.core": mlx_core_module,
                "mlx_vlm": mlx_vlm_module,
                "mlx_vlm.prompt_utils": prompt_utils_module,
            },
        ), patch.object(
            python_bridge, "load_model_if_needed", fake_load_model_if_needed
        ), patch("sys.stdout", new_callable=io.StringIO) as captured:
            python_bridge.handle_chat_completion(request)

        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]

        self.assertEqual(messages[-1]["type"], "error")
        mlx_core_module.clear_cache.assert_called_once()

    def test_chat_completion_emits_bridge_generation_tps_after_model_loaded(self):
        loaded = {"value": False, "observed_by_stream": False}

        def fake_load_model_if_needed(model_id, request=None):
            loaded["value"] = True
            return ("model", object(), {"model_type": "fake"})

        def fake_apply_chat_template(processor, config, messages, num_images=0, **kwargs):
            return "prompt"

        def fake_stream_generate(*args, **kwargs):
            loaded["observed_by_stream"] = loaded["value"]
            yield types.SimpleNamespace(
                text="A",
                prompt_tokens=7,
                generation_tokens=1,
                prompt_tps=70.0,
                generation_tps=10.0,
                peak_memory=1.25,
            )
            yield types.SimpleNamespace(
                text="B",
                prompt_tokens=7,
                generation_tokens=2,
                prompt_tps=70.0,
                generation_tps=12.5,
                peak_memory=1.25,
            )

        mlx_vlm_module = types.ModuleType("mlx_vlm")
        mlx_vlm_module.stream_generate = fake_stream_generate
        prompt_utils_module = types.ModuleType("mlx_vlm.prompt_utils")
        prompt_utils_module.apply_chat_template = fake_apply_chat_template
        mlx_module = types.ModuleType("mlx")
        mlx_core_module = types.ModuleType("mlx.core")
        mlx_core_module.clear_cache = lambda: None
        mlx_module.core = mlx_core_module

        request = {
            "type": "chat.completions",
            "model": "fake-model",
            "messages": [{"role": "user", "content": "hello"}],
            "request_id": "req-perf",
        }

        with patch.dict(
            sys.modules,
            {
                "mlx": mlx_module,
                "mlx.core": mlx_core_module,
                "mlx_vlm": mlx_vlm_module,
                "mlx_vlm.prompt_utils": prompt_utils_module,
            },
        ), patch.object(
            python_bridge, "load_model_if_needed", fake_load_model_if_needed
        ), patch("sys.stdout", new_callable=io.StringIO) as captured:
            python_bridge.handle_chat_completion(request)

        assert loaded["observed_by_stream"] is True
        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]
        complete = messages[-1]

        assert complete["type"] == "chat.completion.complete"
        assert complete["choices"][0]["message"]["content"] == "AB"
        assert complete["usage"] == {"prompt_tokens": 7, "completion_tokens": 2}
        assert complete["performance"]["tokens_per_second"] == 12.5
        assert complete["performance"]["generation_tokens_per_second"] == 12.5
        assert complete["performance"]["prompt_tokens_per_second"] == 70.0
        assert complete["performance"]["generation_duration"] == 0.16
        assert complete["performance"]["peak_memory_gb"] == 1.25

    def test_chat_completion_emits_timing_events_when_enabled(self):
        def fake_load_model_if_needed(model_id, request=None):
            return ("model", object(), {"model_type": "fake"})

        def fake_apply_chat_template(processor, config, messages, num_images=0, **kwargs):
            return "prompt"

        def fake_stream_generate(*args, **kwargs):
            yield types.SimpleNamespace(
                text="A",
                prompt_tokens=7,
                generation_tokens=1,
                prompt_tps=70.0,
                generation_tps=10.0,
                peak_memory=1.25,
            )

        mlx_vlm_module = types.ModuleType("mlx_vlm")
        mlx_vlm_module.stream_generate = fake_stream_generate
        prompt_utils_module = types.ModuleType("mlx_vlm.prompt_utils")
        prompt_utils_module.apply_chat_template = fake_apply_chat_template
        mlx_module = types.ModuleType("mlx")
        mlx_core_module = types.ModuleType("mlx.core")
        mlx_core_module.clear_cache = lambda: None
        mlx_module.core = mlx_core_module

        request = {
            "type": "chat.completions",
            "model": "fake-model",
            "messages": [{"role": "user", "content": "hello"}],
            "request_id": "req-timing",
        }

        with patch.dict(
            os.environ, {"MLXTRA_BRIDGE_TIMING": "1"}
        ), patch.dict(
            sys.modules,
            {
                "mlx": mlx_module,
                "mlx.core": mlx_core_module,
                "mlx_vlm": mlx_vlm_module,
                "mlx_vlm.prompt_utils": prompt_utils_module,
            },
        ), patch.object(
            python_bridge, "load_model_if_needed", fake_load_model_if_needed
        ), patch("sys.stdout", new_callable=io.StringIO) as captured:
            python_bridge.handle_chat_completion(request)

        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]
        timing_names = {
            message["name"]
            for message in messages
            if message.get("type") == "trace.timing"
        }

        assert "chat.imports" in timing_names
        assert "chat.model_ready" in timing_names
        assert "chat.prompt_template" in timing_names
        assert "chat.first_token" in timing_names
        assert "chat.generation" in timing_names
        assert "chat.request_total" in timing_names
        assert any(
            message.get("type") == "chat.completion.complete" for message in messages
        )


class TestModelLoadTiming(unittest.TestCase):
    def tearDown(self):
        python_bridge.MODEL_REGISTRY.clear()

    def test_load_model_if_needed_emits_weight_load_timing_when_enabled(self):
        python_bridge.MODEL_REGISTRY.clear()

        def fake_load(model_id):
            return ("model", "processor")

        def fake_load_config(model_id):
            return {"model_type": "fake"}

        mlx_vlm_module = types.ModuleType("mlx_vlm")
        mlx_vlm_module.load = fake_load
        mlx_vlm_utils_module = types.ModuleType("mlx_vlm.utils")
        mlx_vlm_utils_module.load_config = fake_load_config

        request = {"request_id": "req-load"}

        with patch.dict(
            os.environ, {"MLXTRA_BRIDGE_TIMING": "1"}
        ), patch.dict(
            sys.modules,
            {
                "mlx_vlm": mlx_vlm_module,
                "mlx_vlm.utils": mlx_vlm_utils_module,
            },
        ), patch("sys.stdout", new_callable=io.StringIO) as captured:
            python_bridge.load_model_if_needed("fake-model", request=request)

        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]
        timing_names = {
            message["name"]
            for message in messages
            if message.get("type") == "trace.timing"
        }

        assert "model.mlx_imports" in timing_names
        assert "model.weights" in timing_names
        assert "model.config" in timing_names
        assert "model.warmup" in timing_names
        assert "model.load_total" in timing_names
        assert any(message.get("type") == "model.loaded" for message in messages)


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


class TestMediaGenerationBridge(unittest.TestCase):
    def test_image_generation_missing_model_does_not_import_mlx(self):
        original_import = builtins.__import__

        def import_without_mlx(name, *args, **kwargs):
            if name == "mlx" or name.startswith("mlx."):
                raise ModuleNotFoundError("No module named 'mlx'")
            return original_import(name, *args, **kwargs)

        with patch.object(
            builtins, "__import__", side_effect=import_without_mlx
        ), patch("sys.stdout", new_callable=io.StringIO) as captured:
            python_bridge.handle_image_generation(
                {
                    "type": "image.generate",
                    "request_id": "req-image-missing-model",
                }
            )

        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]

        self.assertEqual(messages[-1]["type"], "error")
        self.assertEqual(
            messages[-1]["message"],
            "No model provided for image generation",
        )
        self.assertEqual(messages[-1]["request_id"], "req-image-missing-model")

    def test_audio_generation_missing_model_does_not_import_mlx(self):
        original_import = builtins.__import__

        def import_without_mlx(name, *args, **kwargs):
            if name == "mlx" or name.startswith("mlx."):
                raise ModuleNotFoundError("No module named 'mlx'")
            return original_import(name, *args, **kwargs)

        with patch.object(
            builtins, "__import__", side_effect=import_without_mlx
        ), patch("sys.stdout", new_callable=io.StringIO) as captured:
            python_bridge.handle_audio_speech(
                {
                    "type": "audio.speech",
                    "request_id": "req-audio-missing-model",
                }
            )

        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]

        self.assertEqual(messages[-1]["type"], "error")
        self.assertEqual(
            messages[-1]["message"],
            "No model provided for speech generation",
        )
        self.assertEqual(messages[-1]["request_id"], "req-audio-missing-model")

    def test_image_generation_honors_explicit_zero_seed(self):
        class FakeImage:
            def save(self, path, overwrite=False):
                Path(path).write_bytes(b"png")

        class FakeImageModel:
            def __init__(self):
                self.kwargs = None

            def generate_image(self, **kwargs):
                self.kwargs = kwargs
                return FakeImage()

        fake_model = FakeImageModel()
        fake_mx = types.ModuleType("mlx.core")
        fake_mx.clear_cache = MagicMock()
        mlx_module = types.ModuleType("mlx")
        mlx_module.core = fake_mx

        with tempfile.TemporaryDirectory() as output_dir, patch.dict(
            sys.modules,
            {"mlx": mlx_module, "mlx.core": fake_mx},
        ), patch.object(
            python_bridge, "load_image_model_if_needed", return_value=fake_model
        ), patch("sys.stdout", new_callable=io.StringIO) as captured:
            python_bridge.handle_image_generation(
                {
                    "type": "image.generate",
                    "model": "image-model",
                    "prompt": "draw",
                    "parameters": {"seed": 0},
                    "output_dir": output_dir,
                    "request_id": "req-image-zero-seed",
                }
            )

        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]

        self.assertEqual(fake_model.kwargs["seed"], 0)
        self.assertEqual(messages[-2]["type"], "image.generated")
        self.assertEqual(messages[-2]["seed"], 0)
        fake_mx.clear_cache.assert_called_once()

    def test_ideogram_image_generation_passes_structured_caption_and_options(self):
        class FakeImage:
            def save(self, path, overwrite=False):
                Path(path).write_bytes(b"png")

        class FakeImageModel:
            def __init__(self):
                self.kwargs = None

            def generate_image(self, **kwargs):
                self.kwargs = kwargs
                return FakeImage()

        fake_model = FakeImageModel()
        fake_mx = types.ModuleType("mlx.core")
        fake_mx.clear_cache = MagicMock()
        mlx_module = types.ModuleType("mlx")
        mlx_module.core = fake_mx
        caption = {
            "compositional_deconstruction": {
                "elements": [
                    {
                        "desc": "Poster title",
                        "text": "HELLO",
                        "bbox": [100, 100, 900, 300],
                        "type": "text",
                    }
                ],
                "background": "Dark blue",
            },
            "style_description": {
                "medium": "graphic design",
                "art_style": "modern poster",
                "lighting": "flat",
                "aesthetics": "minimal",
            },
            "high_level_description": "A typography poster",
        }

        with tempfile.TemporaryDirectory() as output_dir, patch.dict(
            sys.modules,
            {"mlx": mlx_module, "mlx.core": fake_mx},
        ), patch.object(
            python_bridge, "load_image_model_if_needed", return_value=fake_model
        ), patch("sys.stdout", new_callable=io.StringIO):
            python_bridge.handle_image_generation(
                {
                    "type": "image.generate",
                    "model": "ideogram-ai/ideogram-4-fp8",
                    "prompt": caption,
                    "parameters": {
                        "preset": "V4_QUALITY_48",
                        "use_preset_steps": True,
                        "strict_caption_validation": True,
                        "warn_on_caption_issues": False,
                        "runtimeOptions": {
                            "mflux": {
                                "config": "ideogram-4-fp8",
                                "textToImageClass": "Ideogram4",
                            }
                        },
                    },
                    "output_dir": output_dir,
                    "request_id": "req-ideogram-caption",
                }
            )

        self.assertEqual(
            list(fake_model.kwargs["prompt"]),
            [
                "high_level_description",
                "style_description",
                "compositional_deconstruction",
            ],
        )
        self.assertEqual(
            list(fake_model.kwargs["prompt"]["style_description"]),
            ["aesthetics", "lighting", "medium", "art_style"],
        )
        self.assertEqual(
            list(
                fake_model.kwargs["prompt"]["compositional_deconstruction"][
                    "elements"
                ][0]
            ),
            ["type", "bbox", "text", "desc"],
        )
        self.assertEqual(fake_model.kwargs["preset"], "V4_QUALITY_48")
        self.assertTrue(fake_model.kwargs["use_preset_steps"])
        self.assertTrue(fake_model.kwargs["strict_caption_validation"])
        self.assertFalse(fake_model.kwargs["warn_on_caption_issues"])
        fake_mx.clear_cache.assert_called_once()

    def test_ideogram_image_generation_rejects_plain_prompt_before_model_load(self):
        request = {
            "type": "image.generate",
            "model": "ideogram-ai/ideogram-4-fp8",
            "prompt": "Create a poster",
            "parameters": {
                "strict_caption_validation": False,
                "runtimeOptions": {
                    "mflux": {
                        "config": "ideogram-4-fp8",
                        "textToImageClass": "Ideogram4",
                    }
                },
            },
            "request_id": "req-ideogram-plain-prompt",
        }

        with tempfile.TemporaryDirectory() as output_dir, patch.object(
            python_bridge, "load_image_model_if_needed"
        ) as load_model, patch("sys.stdout", new_callable=io.StringIO) as captured:
            request["output_dir"] = output_dir
            python_bridge.handle_image_generation(request)

        load_model.assert_not_called()
        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]
        self.assertEqual(messages[-1]["type"], "error")
        self.assertIn("requires a structured JSON caption object", messages[-1]["message"])

    def test_image_generation_emits_mflux_callback_progress(self):
        class FakeImage:
            def save(self, path, overwrite=False):
                Path(path).write_bytes(b"png")

        class FakeCallbacks:
            def __init__(self):
                self.in_loop = []
                self.before_loop = []
                self.after_loop = []
                self.interrupt = []

            def register(self, callback):
                if hasattr(callback, "call_in_loop"):
                    self.in_loop.append(callback)

        class FakeConfig:
            num_inference_steps = 2

        class FakeImageModel:
            def __init__(self):
                self.callbacks = FakeCallbacks()

            def generate_image(self, **kwargs):
                for callback in list(self.callbacks.in_loop):
                    callback.call_in_loop(0, kwargs["seed"], kwargs["prompt"], None, FakeConfig(), range(2))
                    callback.call_in_loop(1, kwargs["seed"], kwargs["prompt"], None, FakeConfig(), range(2))
                return FakeImage()

        fake_model = FakeImageModel()
        fake_mx = types.ModuleType("mlx.core")
        fake_mx.clear_cache = MagicMock()
        mlx_module = types.ModuleType("mlx")
        mlx_module.core = fake_mx

        with tempfile.TemporaryDirectory() as output_dir, patch.dict(
            sys.modules,
            {"mlx": mlx_module, "mlx.core": fake_mx},
        ), patch.object(
            python_bridge, "load_image_model_if_needed", return_value=fake_model
        ), patch("sys.stdout", new_callable=io.StringIO) as captured:
            python_bridge.handle_image_generation(
                {
                    "type": "image.generate",
                    "model": "image-model",
                    "prompt": "draw",
                    "parameters": {"steps": 2, "seed": 7},
                    "output_dir": output_dir,
                    "request_id": "req-image-progress",
                }
            )

        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]
        progress_messages = [
            message for message in messages if message["type"] == "generation.progress"
        ]

        self.assertEqual(fake_model.callbacks.in_loop, [])
        self.assertTrue(any(message["phase"] == "denoising" for message in progress_messages))
        self.assertTrue(any(message["percent"] == 90 for message in progress_messages))
        self.assertEqual(progress_messages[-1]["phase"], "complete")
        self.assertEqual(progress_messages[-1]["percent"], 100)
        self.assertFalse(progress_messages[-1]["estimated"])
        fake_mx.clear_cache.assert_called_once()

    def test_image_generation_coerces_invalid_parameters_to_defaults(self):
        class FakeImage:
            def save(self, path, overwrite=False):
                Path(path).write_bytes(b"png")

        class FakeImageModel:
            def __init__(self):
                self.kwargs = None

            def generate_image(self, **kwargs):
                self.kwargs = kwargs
                return FakeImage()

        fake_model = FakeImageModel()
        fake_mx = types.ModuleType("mlx.core")
        fake_mx.clear_cache = MagicMock()
        mlx_module = types.ModuleType("mlx")
        mlx_module.core = fake_mx

        with tempfile.TemporaryDirectory() as output_dir, patch.dict(
            sys.modules,
            {"mlx": mlx_module, "mlx.core": fake_mx},
        ), patch.object(
            python_bridge, "load_image_model_if_needed", return_value=fake_model
        ), patch(
            "time.time_ns", return_value=123
        ), patch("sys.stdout", new_callable=io.StringIO):
            python_bridge.handle_image_generation(
                {
                    "type": "image.generate",
                    "model": "image-model",
                    "prompt": "draw",
                    "parameters": {
                        "width": "wide",
                        "height": 0,
                        "steps": "many",
                        "guidance": "strong",
                        "seed": "fixed",
                    },
                    "output_dir": output_dir,
                    "request_id": "req-image-invalid-params",
                }
            )

        self.assertEqual(fake_model.kwargs["width"], 1024)
        self.assertEqual(fake_model.kwargs["height"], 1024)
        self.assertEqual(fake_model.kwargs["num_inference_steps"], 4)
        self.assertEqual(fake_model.kwargs["guidance"], 1.0)
        self.assertEqual(fake_model.kwargs["seed"], 123)
        fake_mx.clear_cache.assert_called_once()

    def test_image_generation_clears_mlx_cache_after_error(self):
        class FailingImageModel:
            def generate_image(self, **kwargs):
                raise RuntimeError("image failed")

        fake_mx = types.ModuleType("mlx.core")
        fake_mx.clear_cache = MagicMock()
        mlx_module = types.ModuleType("mlx")
        mlx_module.core = fake_mx

        with tempfile.TemporaryDirectory() as output_dir, patch.dict(
            sys.modules,
            {"mlx": mlx_module, "mlx.core": fake_mx},
        ), patch.object(
            python_bridge, "load_image_model_if_needed", return_value=FailingImageModel()
        ), patch("sys.stdout", new_callable=io.StringIO) as captured:
            python_bridge.handle_image_generation(
                {
                    "type": "image.generate",
                    "model": "image-model",
                    "prompt": "draw",
                    "output_dir": output_dir,
                    "request_id": "req-image-error",
                }
            )

        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]

        self.assertEqual(messages[-1]["type"], "error")
        fake_mx.clear_cache.assert_called_once()

    def test_audio_generation_clears_mlx_cache_when_no_audio_is_returned(self):
        fake_mx = types.ModuleType("mlx.core")
        fake_mx.clear_cache = MagicMock()
        mlx_module = types.ModuleType("mlx")
        mlx_module.core = fake_mx

        with tempfile.TemporaryDirectory() as output_dir, patch.dict(
            sys.modules,
            {"mlx": mlx_module, "mlx.core": fake_mx},
        ), patch.object(
            python_bridge, "load_audio_model_if_needed", return_value=object()
        ), patch.object(
            python_bridge, "_generate_speech_segments", return_value=[]
        ), patch("sys.stdout", new_callable=io.StringIO) as captured:
            python_bridge.handle_audio_speech(
                {
                    "type": "audio.speech",
                    "model": "audio-model",
                    "input": "speak",
                    "output_dir": output_dir,
                    "request_id": "req-audio-empty",
                }
            )

        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]

        self.assertEqual(messages[-1]["type"], "error")
        self.assertIn("without audio", messages[-1]["message"])
        fake_mx.clear_cache.assert_called_once()

    def test_kokoro_audio_generation_emits_segment_progress(self):
        class FakeAudio:
            shape = (120,)

        fake_mx = types.ModuleType("mlx.core")
        fake_mx.clear_cache = MagicMock()
        mlx_module = types.ModuleType("mlx")
        mlx_module.core = fake_mx
        result = types.SimpleNamespace(audio=FakeAudio(), sample_rate=24000)

        with tempfile.TemporaryDirectory() as output_dir, patch.dict(
            sys.modules,
            {"mlx": mlx_module, "mlx.core": fake_mx},
        ), patch.object(
            python_bridge, "load_audio_model_if_needed", return_value=object()
        ), patch.object(
            python_bridge, "_generate_speech_segments", return_value=[result]
        ), patch.object(
            python_bridge, "_write_wav"
        ) as write_wav, patch("sys.stdout", new_callable=io.StringIO) as captured:
            python_bridge.handle_audio_speech(
                {
                    "type": "audio.speech",
                    "model": "kokoro-model",
                    "input": "speak",
                    "parameters": {
                        "runtimeOptions": {
                            "audio": {"adapter": "kokoro", "defaultVoice": "af_heart"}
                        }
                    },
                    "output_dir": output_dir,
                    "request_id": "req-kokoro-progress",
                }
            )

        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]
        progress_messages = [
            message for message in messages if message["type"] == "generation.progress"
        ]

        self.assertTrue(any(message["phase"] == "synthesizing" for message in progress_messages))
        self.assertTrue(any(message.get("estimated") is True for message in progress_messages))
        self.assertEqual(progress_messages[-1]["phase"], "complete")
        self.assertEqual(progress_messages[-1]["percent"], 100)
        self.assertFalse(progress_messages[-1]["estimated"])
        write_wav.assert_called_once()
        fake_mx.clear_cache.assert_called_once()

    def test_kugelaudio_audio_generation_marks_progress_estimated(self):
        class FakeAudio:
            shape = (120,)

        fake_mx = types.ModuleType("mlx.core")
        fake_mx.clear_cache = MagicMock()
        mlx_module = types.ModuleType("mlx")
        mlx_module.core = fake_mx
        result = types.SimpleNamespace(audio=FakeAudio(), sample_rate=24000)

        with tempfile.TemporaryDirectory() as output_dir, patch.dict(
            sys.modules,
            {"mlx": mlx_module, "mlx.core": fake_mx},
        ), patch.object(
            python_bridge, "load_audio_model_if_needed", return_value=object()
        ), patch.object(
            python_bridge, "_generate_speech_segments", return_value=[result]
        ), patch.object(
            python_bridge, "_write_wav"
        ), patch("sys.stdout", new_callable=io.StringIO) as captured:
            python_bridge.handle_audio_speech(
                {
                    "type": "audio.speech",
                    "model": "kugelaudio-model",
                    "input": "speak",
                    "parameters": {
                        "runtimeOptions": {
                            "audio": {"adapter": "kugelaudio", "defaultVoice": "default"}
                        }
                    },
                    "output_dir": output_dir,
                    "request_id": "req-kugel-progress",
                }
            )

        messages = [
            json.loads(line)
            for line in captured.getvalue().splitlines()
            if line.strip()
        ]
        progress_messages = [
            message for message in messages if message["type"] == "generation.progress"
        ]

        self.assertTrue(progress_messages)
        self.assertTrue(any(message.get("estimated") is True for message in progress_messages))
        self.assertEqual(progress_messages[-1]["phase"], "complete")
        self.assertFalse(progress_messages[-1]["estimated"])
        fake_mx.clear_cache.assert_called_once()


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

    def test_inherits_request_id_from_request(self):
        import io
        from contextlib import redirect_stdout

        captured = io.StringIO()
        with redirect_stdout(captured):
            python_bridge.send_json(
                {"type": "test"},
                request={"request_id": "req-123"},
            )
        parsed = json.loads(captured.getvalue().strip())
        assert parsed["request_id"] == "req-123"

    def test_send_generation_progress_outputs_clamped_percentage(self):
        import io
        from contextlib import redirect_stdout

        captured = io.StringIO()
        with redirect_stdout(captured):
            python_bridge.send_generation_progress(
                "image-model",
                "denoising",
                backend="image",
                request={"request_id": "req-progress"},
                message="Denoising image",
                fraction=1.4,
                estimated=False,
            )

        parsed = json.loads(captured.getvalue().strip())
        self.assertEqual(parsed["type"], "generation.progress")
        self.assertEqual(parsed["request_id"], "req-progress")
        self.assertEqual(parsed["model"], "image-model")
        self.assertEqual(parsed["backend"], "image")
        self.assertEqual(parsed["phase"], "denoising")
        self.assertEqual(parsed["message"], "Denoising image")
        self.assertEqual(parsed["fraction"], 1.0)
        self.assertEqual(parsed["percent"], 100)
        self.assertFalse(parsed["estimated"])


class TestRequestIDPropagation(unittest.TestCase):
    def test_handle_init_includes_request_id(self):
        import io
        from contextlib import redirect_stdout

        captured = io.StringIO()
        with patch.object(python_bridge, "load_model_if_needed") as mock_load:
            with redirect_stdout(captured):
                python_bridge.handle_init(
                    {
                        "type": "init",
                        "request_id": "req-789",
                        "backend": "vlm",
                        "model_id": "test-model",
                    }
                )

        mock_load.assert_called_once()
        parsed = json.loads(captured.getvalue().strip().splitlines()[-1])
        assert parsed["type"] == "model.initialized"
        assert parsed["request_id"] == "req-789"


class TestLogDebug(unittest.TestCase):
    def test_disabled_by_default(self):
        import io
        from contextlib import redirect_stderr

        captured = io.StringIO()
        with patch.dict(os.environ, {}, clear=True), redirect_stderr(captured):
            python_bridge.log_debug("test message")
        assert captured.getvalue() == ""

    def test_uses_stderr_when_enabled(self):
        import io
        from contextlib import redirect_stderr

        captured = io.StringIO()
        with patch.dict(os.environ, {"MLXTRA_BRIDGE_DEBUG": "1"}), redirect_stderr(captured):
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

    def test_unload_models_preserves_keep_key(self):
        keep_value = object()
        python_bridge.MODEL_REGISTRY["keep"] = keep_value
        python_bridge.MODEL_REGISTRY["drop"] = object()
        python_bridge.IMAGE_MODEL_REGISTRY["image"] = object()
        python_bridge.AUDIO_MODEL_REGISTRY["audio"] = object()
        python_bridge.MUSIC_MODEL_REGISTRY["music"] = object()

        python_bridge.unload_models(
            keep_registry=python_bridge.MODEL_REGISTRY,
            keep_key="keep",
        )

        assert python_bridge.MODEL_REGISTRY == {"keep": keep_value}
        assert python_bridge.IMAGE_MODEL_REGISTRY == {}
        assert python_bridge.AUDIO_MODEL_REGISTRY == {}
        assert python_bridge.MUSIC_MODEL_REGISTRY == {}

    def test_unload_models_does_not_import_mlx_for_cache_clear(self):
        python_bridge.MODEL_REGISTRY["drop"] = object()
        sys.modules.pop("mlx.core", None)

        python_bridge.unload_models()

        assert "mlx.core" not in sys.modules
        assert python_bridge.MODEL_REGISTRY == {}

    def test_clear_accelerator_cache_uses_existing_mlx_module(self):
        fake_mx = MagicMock()

        with patch.dict(sys.modules, {"mlx.core": fake_mx}):
            python_bridge._clear_accelerator_cache()

        fake_mx.clear_cache.assert_called_once()

    def test_music_init_remains_lazy(self):
        python_bridge.MUSIC_MODEL_REGISTRY.clear()

        with patch.object(python_bridge, "send_json") as mock_send_json:
            python_bridge.handle_init(
                {
                    "type": "init",
                    "backend": "music",
                    "model_id": "ACE-Step/acestep-v15-turbo-continuous",
                    "request_id": "req-music-init",
                }
            )

        assert python_bridge.MUSIC_MODEL_REGISTRY == {}
        mock_send_json.assert_called_once_with(
            {
                "type": "model.initialized",
                "model": "ACE-Step/acestep-v15-turbo-continuous",
            },
            request={
                "type": "init",
                "backend": "music",
                "model_id": "ACE-Step/acestep-v15-turbo-continuous",
                "request_id": "req-music-init",
            },
        )


class TestBridgeProtocolSequences(unittest.TestCase):
    def test_image_then_music_then_chat_same_session(self):
        launcher = self._make_launcher_script()
        commands = [
            {
                "type": "init",
                "backend": "image",
                "model_id": "image-model",
                "request_id": "req-image-init",
            },
            {
                "type": "image.generate",
                "model": "image-model",
                "prompt": "image",
                "request_id": "req-image",
            },
            {
                "type": "init",
                "backend": "music",
                "model_id": "music-model",
                "request_id": "req-music-init",
            },
            {
                "type": "music.generate",
                "model": "music-model",
                "parameters": {"caption": "music"},
                "request_id": "req-music",
            },
            {
                "type": "init",
                "backend": "vlm",
                "model_id": "chat-model",
                "request_id": "req-chat-init",
            },
            {
                "type": "chat.completions",
                "model": "chat-model",
                "messages": [{"role": "user", "content": "hello"}],
                "request_id": "req-chat",
            },
        ]

        messages = self._run_launcher_session(launcher, commands)
        messages_by_request = {}
        for message in messages:
            request_id = message.get("request_id")
            if request_id:
                messages_by_request.setdefault(request_id, []).append(message["type"])

        self.assertEqual(messages_by_request["req-image-init"], ["model.loaded"])
        self.assertEqual(messages_by_request["req-image"], ["image.generated", "chat.completion.complete"])
        self.assertEqual(messages_by_request["req-music-init"], ["model.initialized"])
        self.assertEqual(messages_by_request["req-music"], ["model.loaded", "audio.generated", "chat.completion.complete"])
        self.assertEqual(messages_by_request["req-chat-init"], ["model.loaded", "model.initialized"])
        self.assertEqual(messages_by_request["req-chat"], ["chat.completion.chunk", "chat.completion.complete"])

    def test_tool_call_then_followup_completion_same_session(self):
        launcher = self._make_launcher_script()
        commands = [
            {
                "type": "init",
                "backend": "vlm",
                "model_id": "chat-model",
                "request_id": "req-init",
            },
            {
                "type": "chat.completions",
                "model": "chat-model",
                "messages": [{"role": "user", "content": "use a tool"}],
                "tools": [{"type": "function", "function": {"name": "generate_music"}}],
                "request_id": "req-tool",
            },
            {
                "type": "chat.completions",
                "model": "chat-model",
                "messages": [
                    {"role": "user", "content": "use a tool"},
                    {
                        "role": "assistant",
                        "tool_calls": [
                            {
                                "id": "tool-call-1",
                                "function": {
                                    "name": "generate_music",
                                    "arguments": json.dumps({"caption": "music please"}),
                                },
                            }
                        ],
                    },
                    {"role": "tool", "tool_call_id": "tool-call-1", "content": "done"},
                ],
                "request_id": "req-followup",
            },
        ]

        messages = self._run_launcher_session(launcher, commands)
        by_request = {}
        for message in messages:
            request_id = message.get("request_id")
            if request_id:
                by_request.setdefault(request_id, []).append(message)

        self.assertEqual(by_request["req-tool"][0]["type"], "chat.completion.tool_calls")
        self.assertEqual(by_request["req-followup"][0]["type"], "chat.completion.chunk")
        self.assertEqual(
            by_request["req-followup"][1]["choices"][0]["message"]["content"],
            "follow-up complete",
        )

    def _make_launcher_script(self):
        resources_dir = Path(__file__).resolve().parents[2] / "MLXtra" / "Resources"
        launcher = Path(tempfile.mkdtemp()) / "bridge_launcher.py"
        launcher.write_text(
            f"""import json\nimport sys\nsys.path.insert(0, {str(resources_dir)!r})\nimport python_bridge\n\n"""
            + """
def fake_load_model_if_needed(model_id, request=None):
    python_bridge.unload_models(keep_registry=python_bridge.MODEL_REGISTRY, keep_key=model_id)
    python_bridge.MODEL_REGISTRY[model_id] = ("model", "processor", {})
    python_bridge.send_json({"type": "model.loaded", "model": model_id}, request=request)
    return python_bridge.MODEL_REGISTRY[model_id]

def fake_load_image_model_if_needed(model_id, edit=False, request=None):
    cache_key = f"{model_id}:{'edit' if edit else 'txt2img'}"
    python_bridge.unload_models(keep_registry=python_bridge.IMAGE_MODEL_REGISTRY, keep_key=cache_key)
    python_bridge.IMAGE_MODEL_REGISTRY[cache_key] = {"model": model_id}
    python_bridge.send_json({"type": "model.loaded", "model": model_id}, request=request)
    return python_bridge.IMAGE_MODEL_REGISTRY[cache_key]

def fake_load_music_model_if_needed(model_id, request=None):
    python_bridge.unload_models(keep_registry=python_bridge.MUSIC_MODEL_REGISTRY, keep_key=model_id)
    python_bridge.MUSIC_MODEL_REGISTRY[model_id] = ("dit", "llm")
    python_bridge.send_json({"type": "model.loaded", "model": model_id}, request=request)
    return python_bridge.MUSIC_MODEL_REGISTRY[model_id]

def fake_handle_chat_completion(request):
    model_id = request.get("model")
    if model_id not in python_bridge.MODEL_REGISTRY:
        python_bridge.send_json({"type": "error", "message": "chat model not loaded"}, request=request)
        return
    if request.get("tools"):
        python_bridge.send_json(
            {
                "type": "chat.completion.tool_calls",
                "tool_calls": [
                    {
                        "id": "tool-call-1",
                        "function": {
                            "name": "generate_music",
                            "arguments": json.dumps({"caption": "music please"})
                        }
                    }
                ]
            },
            request=request,
        )
        return
    python_bridge.send_json({"type": "chat.completion.chunk", "choices": [{"delta": {"content": "ok"}}]}, request=request)
    last_message = (request.get("messages") or [{}])[-1]
    content = "follow-up complete" if last_message.get("role") == "tool" else "chat complete"
    python_bridge.send_json(
        {
            "type": "chat.completion.complete",
            "choices": [{"message": {"content": content}}],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0},
        },
        request=request,
    )

def fake_handle_image_generation(request):
    model_id = request.get("model")
    cache_key = f"{model_id}:txt2img"
    if cache_key not in python_bridge.IMAGE_MODEL_REGISTRY:
        python_bridge.send_json({"type": "error", "message": "image model not loaded"}, request=request)
        return
    python_bridge.send_json({"type": "image.generated", "path": "/tmp/generated-image.png"}, request=request)
    python_bridge.send_json(
        {
            "type": "chat.completion.complete",
            "choices": [{"message": {"content": "image complete"}}],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0},
        },
        request=request,
    )

def fake_handle_music_generation(request):
    model_id = request.get("model")
    if model_id not in python_bridge.MUSIC_MODEL_REGISTRY:
        fake_load_music_model_if_needed(model_id, request=request)
    python_bridge.send_json({"type": "audio.generated", "path": "/tmp/generated-music.wav"}, request=request)
    python_bridge.send_json(
        {
            "type": "chat.completion.complete",
            "choices": [{"message": {"content": "music complete"}}],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0},
        },
        request=request,
    )

python_bridge.load_model_if_needed = fake_load_model_if_needed
python_bridge.load_image_model_if_needed = fake_load_image_model_if_needed
python_bridge.load_music_model_if_needed = fake_load_music_model_if_needed
python_bridge.handle_chat_completion = fake_handle_chat_completion
python_bridge.handle_image_generation = fake_handle_image_generation
python_bridge.handle_music_generation = fake_handle_music_generation
python_bridge.main()
"""
        )
        self.addCleanup(lambda: launcher.parent.exists() and __import__("shutil").rmtree(launcher.parent, ignore_errors=True))
        return launcher

    def _run_launcher_session(self, launcher, commands):
        process = subprocess.Popen(
            [sys.executable, str(launcher)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(lambda: self._terminate_process(process))
        assert process.stdin is not None
        assert process.stdout is not None

        messages = [json.loads(process.stdout.readline())]
        for command in commands:
            process.stdin.write(json.dumps(command) + "\n")
            process.stdin.flush()

        process.stdin.close()
        stdout = process.stdout.read()
        stderr = process.stderr.read()
        return_code = process.wait(timeout=5)
        self.assertEqual(return_code, 0, stderr)
        messages.extend(
            json.loads(line)
            for line in stdout.splitlines()
            if line.strip()
        )
        return messages

    def _terminate_process(self, process):
        if process.stdin is not None and not process.stdin.closed:
            process.stdin.close()
        if process.stdout is not None and not process.stdout.closed:
            process.stdout.close()
        if process.stderr is not None and not process.stderr.closed:
            process.stderr.close()
        if process.poll() is None:
            process.kill()
            process.wait(timeout=1)


class TestAceStepForwarding(unittest.TestCase):
    def test_handle_music_generation_uses_one_shot_magenta_forwarder(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            magenta_python = Path(temp_dir) / "python"
            magenta_python.write_text("#!/bin/sh\n")

            with patch.dict(
                os.environ,
                {"MAGENTA_RT_PYTHON": str(magenta_python)},
            ), patch.object(
                python_bridge, "_forward_magenta_subprocess", return_value=0
            ) as forwarder:
                python_bridge.handle_music_generation(
                    {
                        "request_id": "req-magenta",
                        "type": "music.generate",
                        "model": "google/magenta-realtime-2/mrt2_small",
                        "parameters": {"caption": "clockwork piano"},
                    }
                )

            forwarder.assert_called_once()
            assert Path(forwarder.call_args.args[0]).resolve() == magenta_python.resolve()
            assert forwarder.call_args.args[2]["request_id"] == "req-magenta"

    def test_handle_music_generation_reports_missing_magenta_runtime(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            missing_python = Path(temp_dir) / "missing-magenta-python"
            with patch.object(
                python_bridge,
                "_candidate_magenta_python_paths",
                return_value=[missing_python],
            ), patch.object(python_bridge, "send_json") as send_json:
                python_bridge.handle_music_generation(
                    {
                        "request_id": "req-magenta",
                        "type": "music.generate",
                        "model": "google/magenta-realtime-2/mrt2_base",
                        "parameters": {"caption": "clockwork piano"},
                    }
                )

        send_json.assert_called_once()
        payload = send_json.call_args.args[0]
        assert payload["type"] == "error"
        assert "Magenta RealTime 2 runtime is not installed" in payload["message"]

    def test_handle_music_generation_uses_one_shot_acestep_forwarder(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            ace_python = Path(temp_dir) / "python"
            ace_python.write_text("#!/bin/sh\n")

            with patch.dict(os.environ, {"ACESTEP_PYTHON": str(ace_python)}), patch.object(
                python_bridge, "_forward_acestep_subprocess", return_value=0
            ) as forwarder:
                python_bridge.handle_music_generation(
                    {
                        "request_id": "req-music",
                        "type": "music.generate",
                        "parameters": {"caption": "clockwork piano"},
                    }
                )

            forwarder.assert_called_once()
            assert Path(forwarder.call_args.args[0]).resolve() == ace_python.resolve()
            assert forwarder.call_args.args[2]["request_id"] == "req-music"

    def test_handle_music_generation_finds_acestep_venv_next_to_active_runtime(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            runtime_root = Path(temp_dir) / "runtime" / "macos-arm64"
            main_python = runtime_root / "venv" / "bin" / "python"
            ace_python = runtime_root / "acestep-venv" / "bin" / "python"
            main_python.parent.mkdir(parents=True)
            ace_python.parent.mkdir(parents=True)
            main_python.write_text("#!/bin/sh\n")
            ace_python.write_text("#!/bin/sh\n")

            with patch.dict(os.environ, {}, clear=True), patch.object(
                python_bridge.sys, "executable", str(main_python)
            ), patch.object(
                python_bridge, "_forward_acestep_subprocess", return_value=0
            ) as forwarder:
                python_bridge.handle_music_generation(
                    {
                        "request_id": "req-music",
                        "type": "music.generate",
                        "parameters": {"caption": "clockwork piano"},
                    }
                )

            forwarder.assert_called_once()
            assert Path(forwarder.call_args.args[0]).resolve() == ace_python.resolve()

    def test_handle_music_generation_reports_missing_music_runtime(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            missing_python = Path(temp_dir) / "missing-acestep-python"
            with patch.object(
                python_bridge,
                "_candidate_acestep_python_paths",
                return_value=[missing_python],
            ), patch.object(python_bridge, "send_json") as send_json:
                python_bridge.handle_music_generation(
                    {
                        "request_id": "req-music",
                        "type": "music.generate",
                        "parameters": {"caption": "clockwork piano"},
                    }
                )

        send_json.assert_called_once()
        payload = send_json.call_args.args[0]
        assert payload["type"] == "error"
        assert "Music runtime component is not installed" in payload["message"]

    def test_forward_acestep_subprocess_round_trips_request_id(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            helper = Path(temp_dir) / "helper.py"
            helper.write_text(
                "import json, sys\n"
                "request = json.loads(sys.stdin.readline())\n"
                "print(json.dumps({'type': 'audio.generated', 'request_id': request.get('request_id'), 'path': '/tmp/out.wav'}), flush=True)\n"
            )

            with patch("sys.stdout", new_callable=__import__("io").StringIO) as captured:
                return_code = python_bridge._forward_acestep_subprocess(
                    sys.executable,
                    helper,
                    {"request_id": "req-child", "type": "music.generate"},
                )

            assert return_code == 0
            lines = [json.loads(line) for line in captured.getvalue().splitlines() if line.strip()]
            assert lines[0]["request_id"] == "req-child"

    def test_forward_acestep_subprocess_filters_non_json_stdout(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            helper = Path(temp_dir) / "helper.py"
            helper.write_text(
                "import json, sys\n"
                "print('debug noise', flush=True)\n"
                "request = json.loads(sys.stdin.readline())\n"
                "print(json.dumps({'type': 'audio.generated', 'request_id': request.get('request_id'), 'path': '/tmp/out.wav'}), flush=True)\n"
            )

            with patch("sys.stdout", new_callable=__import__("io").StringIO) as captured_stdout, patch.object(python_bridge, "log_debug") as log_debug:
                return_code = python_bridge._forward_acestep_subprocess(
                    sys.executable,
                    helper,
                    {"request_id": "req-child", "type": "music.generate"},
                )

            assert return_code == 0
            lines = [json.loads(line) for line in captured_stdout.getvalue().splitlines() if line.strip()]
            assert len(lines) == 1
            assert lines[0]["type"] == "audio.generated"
            log_debug.assert_any_call("[ACE-Step stdout ignored] debug noise")

    def test_forward_music_request_drains_stderr_output(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            helper = Path(temp_dir) / "helper.py"
            helper.write_text(
                "import json, sys\n"
                "request = json.loads(sys.stdin.readline())\n"
                "for _ in range(2000):\n"
                "    print('stderr noise ' + ('x' * 80), file=sys.stderr, flush=True)\n"
                "print(json.dumps({'type': 'audio.generated', 'request_id': request.get('request_id'), 'path': '/tmp/out.wav'}), flush=True)\n"
            )

            child = None
            with patch("sys.stdout", new_callable=__import__("io").StringIO) as captured_stdout, patch.object(python_bridge, "log_debug"):
                try:
                    child = python_bridge._ensure_music_subprocess(sys.executable, helper)
                    return_code = python_bridge._forward_music_request(
                        child,
                        {"request_id": "req-music", "type": "music.generate"},
                    )
                finally:
                    if child is not None and child.poll() is None:
                        python_bridge._terminate_child(child, timeout=1)
                    if child is not None:
                        for pipe in (child.stdin, child.stdout, child.stderr):
                            if pipe is not None and not pipe.closed:
                                pipe.close()
                    python_bridge._music_process = None

            assert return_code == 0
            lines = [json.loads(line) for line in captured_stdout.getvalue().splitlines() if line.strip()]
            assert lines == [
                {
                    "type": "audio.generated",
                    "request_id": "req-music",
                    "path": "/tmp/out.wav",
                }
            ]

    def test_forward_music_request_returns_on_completion_without_sentinel(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            helper = Path(temp_dir) / "helper.py"
            helper.write_text(
                "import json, sys, time\n"
                "request = json.loads(sys.stdin.readline())\n"
                "print(json.dumps({'type': 'audio.generated', 'request_id': request.get('request_id'), 'path': '/tmp/out.wav'}), flush=True)\n"
                "print(json.dumps({'type': 'chat.completion.complete', 'request_id': request.get('request_id'), 'choices': [{'message': {'content': 'done'}}]}), flush=True)\n"
                "time.sleep(30)\n"
            )

            child = None
            with patch("sys.stdout", new_callable=__import__("io").StringIO) as captured_stdout:
                try:
                    child = python_bridge._ensure_music_subprocess(sys.executable, helper)
                    return_code = python_bridge._forward_music_request(
                        child,
                        {"request_id": "req-music", "type": "music.generate"},
                    )
                finally:
                    if child is not None and child.poll() is None:
                        python_bridge._terminate_child(child, timeout=1)
                    if child is not None:
                        for pipe in (child.stdin, child.stdout, child.stderr):
                            if pipe is not None and not pipe.closed:
                                pipe.close()
                    python_bridge._music_process = None

            assert return_code == 0
            lines = [json.loads(line) for line in captured_stdout.getvalue().splitlines() if line.strip()]
            assert [line["type"] for line in lines] == ["audio.generated", "chat.completion.complete"]


class TestRuntimeResolution(unittest.TestCase):
    def setUp(self):
        self.original_manifest_cache = python_bridge.RUNTIME_MANIFEST_CACHE
        self.original_espeak_configured_for = python_bridge.ESPEAK_RUNTIME_CONFIGURED_FOR
        python_bridge.RUNTIME_MANIFEST_CACHE = None
        python_bridge.ESPEAK_RUNTIME_CONFIGURED_FOR = None

    def tearDown(self):
        python_bridge.RUNTIME_MANIFEST_CACHE = self.original_manifest_cache
        python_bridge.ESPEAK_RUNTIME_CONFIGURED_FOR = self.original_espeak_configured_for

    def _runtime_site_packages(self, runtime_root: Path) -> Path:
        site_packages = (
            runtime_root / "venv" / "lib" / "python3.12" / "site-packages"
        )
        site_packages.mkdir(parents=True)
        return site_packages

    def test_setup_environment_prefers_active_runtime_packages(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            active_runtime = root / "Application Support" / "runtime"
            bundled_runtime = root / "App.app" / "Contents" / "Resources" / "runtime" / "macos-arm64"
            active_site_packages = self._runtime_site_packages(active_runtime)
            bundled_site_packages = self._runtime_site_packages(bundled_runtime)
            active_python = active_runtime / "venv" / "bin" / "python"
            active_python.parent.mkdir(parents=True)
            active_python.write_text("#!/bin/sh\n")
            bridge_path = bundled_runtime.parent.parent / "python_bridge.py"
            bridge_path.parent.mkdir(parents=True, exist_ok=True)
            bridge_path.write_text("")

            original_sys_path = sys.path[:]
            try:
                sys.path[:] = ["existing"]
                with patch.dict(os.environ, {}, clear=True), patch.object(
                    python_bridge, "__file__", str(bridge_path)
                ), patch.object(python_bridge.sys, "executable", str(active_python)):
                    python_bridge.setup_environment()

                self.assertEqual(sys.path[0], str(active_site_packages.resolve()))
                self.assertEqual(sys.path[1], str(bundled_site_packages.resolve()))
            finally:
                sys.path[:] = original_sys_path

    def test_runtime_manifest_prefers_active_runtime(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            active_runtime = root / "active-runtime"
            bundled_runtime = root / "App.app" / "Contents" / "Resources" / "runtime" / "macos-arm64"
            self._runtime_site_packages(active_runtime)
            self._runtime_site_packages(bundled_runtime)
            active_python = active_runtime / "venv" / "bin" / "python"
            active_python.parent.mkdir(parents=True)
            active_python.write_text("#!/bin/sh\n")
            active_manifest = {"runtime": "active"}
            bundled_manifest = {"runtime": "bundled"}
            (active_runtime / "runtime-manifest.json").write_text(json.dumps(active_manifest))
            (bundled_runtime / "runtime-manifest.json").write_text(json.dumps(bundled_manifest))
            bridge_path = bundled_runtime.parent.parent / "python_bridge.py"
            bridge_path.parent.mkdir(parents=True, exist_ok=True)
            bridge_path.write_text("")

            with patch.dict(os.environ, {}, clear=True), patch.object(
                python_bridge, "__file__", str(bridge_path)
            ), patch.object(python_bridge.sys, "executable", str(active_python)):
                self.assertEqual(python_bridge._runtime_manifest(), active_manifest)

    def test_configure_espeak_runtime_uses_active_runtime_data(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            runtime_root = root / "runtime"
            site_packages = self._runtime_site_packages(runtime_root)
            loader_dir = site_packages / "espeakng_loader"
            data_dir = loader_dir / "espeak-ng-data"
            data_dir.mkdir(parents=True)
            (data_dir / "phontab").write_text("data")
            library_path = loader_dir / "libespeak-ng.dylib"
            library_path.write_text("library")
            active_python = runtime_root / "venv" / "bin" / "python"
            active_python.parent.mkdir(parents=True)
            active_python.write_text("#!/bin/sh\n")

            with patch.dict(os.environ, {}, clear=True), patch.object(
                python_bridge.sys, "executable", str(active_python)
            ):
                configured = python_bridge._configure_espeak_runtime()
                self.assertEqual(configured, loader_dir.resolve())
                self.assertEqual(
                    os.environ["PHONEMIZER_ESPEAK_LIBRARY"],
                    str(library_path.resolve()),
                )
                self.assertEqual(
                    os.environ["PHONEMIZER_ESPEAK_DATA_PATH"],
                    str(data_dir.resolve()),
                )


class TestAudioModelGeneration(unittest.TestCase):
    def test_kokoro_generation_uses_voice_speed_and_language(self):
        generated = object()

        class FakeModel:
            def __init__(self):
                self.calls = []

            def generate(self, **kwargs):
                self.calls.append(kwargs)
                return [generated]

        model = FakeModel()

        result = list(
            python_bridge._generate_speech_segments(
                model,
                "kokoro",
                "hello",
                cfg_scale=3.0,
                ddpm_steps=10,
                voice="bf_emma",
                speed=1.15,
                lang_code="b",
            )
        )

        self.assertEqual(result, [generated])
        self.assertEqual(
            model.calls[0],
            {
                "text": "hello",
                "voice": "bf_emma",
                "speed": 1.15,
                "lang_code": "b",
            },
        )
        request = {
            "parameters": {
                "runtimeOptions": {
                    "audio": {
                        "languageByVoicePrefix": {"bf": "b"}
                    }
                }
            }
        }
        self.assertEqual(python_bridge._lang_code_for_voice(request, "bf_emma"), "b")

    def test_kugelaudio_generation_keeps_existing_cfg_fallback(self):
        generated = object()

        class FakeModel:
            def __init__(self):
                self.calls = []

            def generate(self, **kwargs):
                self.calls.append(kwargs)
                if "voice" in kwargs:
                    raise TypeError("voice is not supported")
                return [generated]

        model = FakeModel()

        result = list(
            python_bridge._generate_speech_segments(
                model,
                "kugelaudio",
                "hello",
                cfg_scale=3.5,
                ddpm_steps=16,
                voice="default",
                speed=1.0,
                lang_code="",
            )
        )

        self.assertEqual(result, [generated])
        self.assertEqual(
            model.calls[2],
            {"text": "hello", "cfg_scale": 3.5, "ddpm_steps": 16},
        )


class TestImageModelLoading(unittest.TestCase):
    def test_passes_model_path_to_mflux(self):
        model_id = "black-forest-labs/FLUX.2-klein-4B"
        mock_model_instance = MagicMock()
        mock_flux_class = MagicMock(return_value=mock_model_instance)
        fake_config = types.SimpleNamespace(model_name=model_id)

        config_module = types.ModuleType("mflux.models.common.config")
        config_module.ModelConfig = types.SimpleNamespace(
            from_name=MagicMock(return_value=fake_config)
        )

        variants_module = types.ModuleType("mflux.models.flux2.variants")
        variants_module.Flux2Klein = mock_flux_class
        variants_module.Flux2KleinEdit = MagicMock()

        stubbed_modules = {
            "mflux": types.ModuleType("mflux"),
            "mflux.models": types.ModuleType("mflux.models"),
            "mflux.models.common": types.ModuleType("mflux.models.common"),
            "mflux.models.common.config": config_module,
            "mflux.models.flux2": types.ModuleType("mflux.models.flux2"),
            "mflux.models.flux2.variants": variants_module,
        }
        request = {
            "parameters": {
                "runtimeOptions": {
                    "mflux": {
                        "config": "flux2-klein-4b",
                        "textToImageClass": "Flux2Klein",
                        "editClass": "Flux2KleinEdit",
                    }
                }
            }
        }

        with patch.dict(sys.modules, stubbed_modules):
            result = python_bridge.load_image_model_if_needed(model_id, request=request)

            config_module.ModelConfig.from_name.assert_called_once_with(model_name="flux2-klein-4b")
            args, kwargs = mock_flux_class.call_args
            assert kwargs["model_path"] == model_id
            assert kwargs["model_config"] == fake_config
            assert result == mock_model_instance

    def test_image_model_requires_runtime_options_config(self):
        with self.assertRaisesRegex(ValueError, "runtimeOptions.mflux.config"):
            python_bridge.load_image_model_if_needed("black-forest-labs/FLUX.2-klein-4B")

    def test_selects_z_image_turbo_runtime_options(self):
        model_id = "Tongyi-MAI/Z-Image-Turbo"
        mock_model_instance = MagicMock()
        mock_z_image_class = MagicMock(return_value=mock_model_instance)
        fake_config = types.SimpleNamespace(model_name=model_id)

        config_module = types.ModuleType("mflux.models.common.config")
        config_module.ModelConfig = types.SimpleNamespace(
            from_name=MagicMock(return_value=fake_config)
        )

        z_image_module = types.ModuleType("mflux.models.z_image")
        z_image_module.ZImage = MagicMock()
        z_image_module.ZImageTurbo = mock_z_image_class

        request = {
            "parameters": {
                "runtimeOptions": {
                    "mflux": {
                        "config": "z-image-turbo",
                        "textToImageClass": "ZImageTurbo",
                        "editClass": "ZImageTurbo",
                        "quantize": 8,
                    }
                }
            }
        }
        stubbed_modules = {
            "mflux": types.ModuleType("mflux"),
            "mflux.models": types.ModuleType("mflux.models"),
            "mflux.models.common": types.ModuleType("mflux.models.common"),
            "mflux.models.common.config": config_module,
            "mflux.models.z_image": z_image_module,
        }

        with patch.dict(sys.modules, stubbed_modules):
            result = python_bridge.load_image_model_if_needed(model_id, request=request)

            config_module.ModelConfig.from_name.assert_called_once_with(model_name="z-image-turbo")
            args, kwargs = mock_z_image_class.call_args
            assert kwargs["model_path"] == model_id
            assert kwargs["model_config"] == fake_config
            assert kwargs["quantize"] == 8
            assert result == mock_model_instance

    def test_selects_ideogram4_text_to_image_runtime_options(self):
        model_id = "ideogram-ai/ideogram-4-fp8"
        mock_model_instance = MagicMock()
        mock_ideogram_class = MagicMock(return_value=mock_model_instance)
        fake_config = types.SimpleNamespace(model_name=model_id)

        config_module = types.ModuleType("mflux.models.common.config")
        config_module.ModelConfig = types.SimpleNamespace(
            from_name=MagicMock(return_value=fake_config)
        )

        ideogram_module = types.ModuleType("mflux.models.ideogram4")
        ideogram_module.Ideogram4 = mock_ideogram_class

        request = {
            "parameters": {
                "runtimeOptions": {
                    "mflux": {
                        "config": "ideogram-4-fp8",
                        "textToImageClass": "Ideogram4",
                    }
                }
            }
        }
        stubbed_modules = {
            "mflux": types.ModuleType("mflux"),
            "mflux.models": types.ModuleType("mflux.models"),
            "mflux.models.common": types.ModuleType("mflux.models.common"),
            "mflux.models.common.config": config_module,
            "mflux.models.ideogram4": ideogram_module,
        }

        with patch.dict(sys.modules, stubbed_modules):
            result = python_bridge.load_image_model_if_needed(model_id, request=request)

            config_module.ModelConfig.from_name.assert_called_once_with(
                model_name="ideogram-4-fp8"
            )
            args, kwargs = mock_ideogram_class.call_args
            assert kwargs["model_path"] == model_id
            assert kwargs["model_config"] == fake_config
            assert kwargs["quantize"] is None
            assert result == mock_model_instance

    def test_text_only_image_model_rejects_edit_request_without_edit_class(self):
        request = {
            "parameters": {
                "runtimeOptions": {
                    "mflux": {
                        "config": "ideogram-4-fp8",
                        "textToImageClass": "Ideogram4",
                    }
                }
            }
        }

        with self.assertRaisesRegex(ValueError, "Image editing is not supported"):
            python_bridge.load_image_model_if_needed(
                "ideogram-ai/ideogram-4-fp8",
                edit=True,
                request=request,
            )


if __name__ == "__main__":
    unittest.main()
