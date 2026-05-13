#!/usr/bin/env python3
"""Unit tests for python_bridge.py"""

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


class TestImageModelLoading(unittest.TestCase):
    def test_passes_model_path_to_mflux(self):
        model_id = "test-org/test-flux-model"
        mock_model_instance = MagicMock()
        mock_flux_class = MagicMock(return_value=mock_model_instance)

        config_module = types.ModuleType("mflux.models.common.config")
        config_module.ModelConfig = types.SimpleNamespace(flux2_klein_4b=MagicMock())

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

        with patch.dict(sys.modules, stubbed_modules):
            result = python_bridge.load_image_model_if_needed(model_id)

            # Check that Flux2Klein was called with model_path=model_id
            args, kwargs = mock_flux_class.call_args
            assert kwargs["model_path"] == model_id
            assert result == mock_model_instance


if __name__ == "__main__":
    unittest.main()
