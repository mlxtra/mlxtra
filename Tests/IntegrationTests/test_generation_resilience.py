#!/usr/bin/env python3
"""Offline, real-model cancellation and sustained generation checks.

Run with MLXTRA_REQUIRE_ALL_MODELS=1 to fail rather than skip missing weights.
HF_HUB_CACHE and MLXTRA_INTEGRATION_OUTPUT_DIR keep test artifacts isolated.
"""

import json
import os
import queue
import subprocess
import threading
import time
import unittest
from pathlib import Path

from test_all_models_integration import MLXtraIntegrationTest
import test_all_models_integration as integration
from runtime_layout import prepared_music_runtime


class GenerationResilienceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bridge = MLXtraIntegrationTest()
        cls.model = os.environ.get(
            "MLXTRA_INTEGRATION_VISION_MODEL", "mlx-community/Qwen3.5-2B-MLX-4bit"
        )
        cls.cache = Path(os.environ.get("HF_HUB_CACHE") or integration.HF_CACHE)
        cls.output = Path(os.environ.get("MLXTRA_INTEGRATION_OUTPUT_DIR") or integration.GENERATED_MUSIC_DIR)
        cls.output.mkdir(parents=True, exist_ok=True)

    def require_chat_model(self):
        snapshots = self.cache / ("models--" + self.model.replace("/", "--")) / "snapshots"
        available = snapshots.exists() and any(
            integration.path_has_content(path) for path in snapshots.rglob("*.safetensors")
        )
        if not available:
            if integration.REQUIRE_ALL_MODELS:
                self.fail("Chat weights missing; downloads disabled")
            self.skipTest("Chat weights missing; downloads disabled")

    def start_bridge(self):
        env = self.bridge.get_bridge_env()
        env.update(HF_HUB_CACHE=str(self.cache), HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
        if os.environ.get("MAGENTA_RT_CHECKPOINTS_DIR"):
            env["MAGENTA_RT_CHECKPOINTS_DIR"] = os.environ["MAGENTA_RT_CHECKPOINTS_DIR"]
        env["MAGENTA_RT_PYTHON"] = str(integration.MUSIC_RUNTIME / "magenta-venv/bin/python")
        stderr = (self.output / (self._testMethodName + ".stderr.log")).open("w")
        self.addCleanup(stderr.close)
        process = subprocess.Popen(
            [str(integration.VENV_PYTHON), "-u", str(integration.BRIDGE_SCRIPT)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
            text=True, bufsize=1, env=env,
        )
        self.addCleanup(self.cleanup_process, process)
        events = queue.Queue()

        def read_output():
            for line in process.stdout:
                try:
                    events.put(json.loads(line))
                except json.JSONDecodeError:
                    events.put({"type": "error", "message": "Non-JSON bridge output: " + line})
            events.put({"type": "eof"})

        threading.Thread(target=read_output, daemon=True).start()
        self.wait_event(events, "system.ready")
        return process, events

    @staticmethod
    def cleanup_process(process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
        for pipe in (process.stdin, process.stdout):
            if pipe:
                pipe.close()

    @staticmethod
    def send(process, request):
        process.stdin.write(json.dumps(request) + "\n")
        process.stdin.flush()

    def wait_event(self, events, kind, timeout=120):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                event = events.get(timeout=max(0.01, deadline - time.monotonic()))
            except queue.Empty:
                break
            self.assertNotIn(event.get("type"), {"error", "eof"}, str(event))
            if event.get("type") == kind:
                return event
        self.fail("Timed out waiting for " + kind)

    def load_chat(self, process, events):
        self.send(process, {"type": "init", "model_id": self.model, "backend": "vlm"})
        self.wait_event(events, "model.loaded")

    def request_chat(self, process, prompt, max_tokens=32):
        self.send(process, {
            "type": "chat.completions", "model": self.model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens, "temperature": 0,
            "chat_template_kwargs": {"enable_thinking": False},
        })

    def assert_restart_answer(self):
        process, events = self.start_bridge()
        self.load_chat(process, events)
        self.request_chat(process, "Reply with exactly 4.")
        answer = ""
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            event = events.get(timeout=max(0.01, deadline - time.monotonic()))
            self.assertNotIn(event.get("type"), {"error", "eof"}, str(event))
            if event.get("type") == "chat.completion.chunk":
                answer += event.get("choices", [{}])[0].get("delta", {}).get("content", "")
            if event.get("type") == "chat.completion.complete":
                break
        else:
            self.fail("Restarted response did not complete")
        self.assertEqual(answer.strip(), "4")
        self.send(process, {"type": "ping"})
        self.wait_event(events, "pong")

    def stop_promptly(self, process):
        started = time.monotonic()
        process.terminate()
        process.wait(timeout=3)
        print("Bridge stopped in %.3fs" % (time.monotonic() - started), flush=True)

    def test_stop_during_loading_then_restart(self):
        self.require_chat_model()
        process, events = self.start_bridge()
        self.send(process, {"type": "init", "model_id": self.model, "backend": "vlm"})
        self.wait_event(events, "model.loading")
        self.stop_promptly(process)
        self.assert_restart_answer()

    def test_stop_during_streaming_then_restart(self):
        self.require_chat_model()
        process, events = self.start_bridge()
        self.load_chat(process, events)
        self.request_chat(process, "Write a detailed 2000-word story about a lighthouse.", 4096)
        self.wait_event(events, "chat.completion.chunk")
        self.stop_promptly(process)
        self.assert_restart_answer()

    def test_long_response_and_repeated_requests(self):
        self.require_chat_model()
        process, events = self.start_bridge()
        self.load_chat(process, events)
        self.request_chat(process, "Write a detailed 2000-word story about a lighthouse.", 512)
        chunks = 0
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            event = events.get(timeout=max(0.01, deadline - time.monotonic()))
            self.assertNotIn(event.get("type"), {"error", "eof"}, str(event))
            if event.get("type") == "chat.completion.chunk":
                chunks += 1
            if event.get("type") == "chat.completion.complete":
                break
        else:
            self.fail("Long response did not complete")
        self.assertGreater(chunks, 100)
        for index in range(3):
            self.request_chat(process, "Reply with exactly 4.")
            answer = ""
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                event = events.get(timeout=max(0.01, deadline - time.monotonic()))
                self.assertNotIn(event.get("type"), {"error", "eof"}, str(event))
                if event.get("type") == "chat.completion.chunk":
                    answer += event.get("choices", [{}])[0].get("delta", {}).get("content", "")
                if event.get("type") == "chat.completion.complete":
                    break
            else:
                self.fail("Repeated response did not complete")
            self.assertEqual(answer.strip(), "4", "Repeated request %d" % (index + 1))
            self.send(process, {"type": "ping"})
            self.wait_event(events, "pong")
        print("Long response: %d chunks, then three successful requests" % chunks, flush=True)

    def test_magenta_twenty_seconds(self):
        checkpoints = Path(os.environ.get("MAGENTA_RT_CHECKPOINTS_DIR") or integration.ACESTEP_CHECKPOINTS_DIR)
        function = checkpoints / "magenta-realtime-2/mrt2_small/models/mrt2_small/mrt2_small.mlxfn"
        if not integration.path_has_content(function):
            if integration.REQUIRE_ALL_MODELS:
                self.fail("Magenta weights missing; downloads disabled")
            self.skipTest("Magenta weights missing; downloads disabled")

        class MagentaBridge(MLXtraIntegrationTest):
            def get_bridge_env(inner_self):
                env = super().get_bridge_env()
                env.update(
                    MAGENTA_RT_CHECKPOINTS_DIR=str(checkpoints),
                    MAGENTA_RT_PYTHON=str(integration.MUSIC_RUNTIME / "magenta-venv/bin/python"),
                    HF_HUB_OFFLINE="1",
                )
                return env

        test = MagentaBridge()
        with prepared_music_runtime(integration.RUNTIME, integration.MUSIC_RUNTIME):
            messages, success = test.send_request_to_bridge({
                "type": "music.generate", "request_id": "resilience-magenta",
                "model": "google/magenta-realtime-2/mrt2_small",
                "prompt": "Warm acoustic guitar and piano instrumental",
                "parameters": {"duration": 20, "seed": 42},
                "output_dir": str(self.output),
            }, timeout=600)
        self.assertTrue(success)
        self.assertTrue(test.require_no_error(messages))
        generated = test.require_message(messages, "audio.generated", "resilience-magenta")
        self.assertIsNotNone(generated)
        self.assertTrue(test.require_completion(messages, "resilience-magenta"))
        self.assertTrue(test.validate_wav(generated["path"], minimum_duration=19, expected_sample_rate=48000))

    def test_stop_music_child_then_restart(self):
        self.require_chat_model()
        checkpoints = Path(os.environ.get("MAGENTA_RT_CHECKPOINTS_DIR") or integration.ACESTEP_CHECKPOINTS_DIR)
        function = checkpoints / "magenta-realtime-2/mrt2_small/models/mrt2_small/mrt2_small.mlxfn"
        if not integration.path_has_content(function):
            if integration.REQUIRE_ALL_MODELS:
                self.fail("Magenta weights missing; downloads disabled")
            self.skipTest("Magenta weights missing; downloads disabled")
        with prepared_music_runtime(integration.RUNTIME, integration.MUSIC_RUNTIME):
            process, events = self.start_bridge()
            self.send(process, {
                "type": "music.generate", "model": "google/magenta-realtime-2/mrt2_small",
                "prompt": "Warm acoustic guitar instrumental",
                "parameters": {"duration": 120, "seed": 42}, "output_dir": str(self.output),
            })
            self.wait_event(events, "generation.progress")
            children = subprocess.check_output(
                ["/bin/ps", "-axo", "pid=,ppid="], text=True
            )
            child_pids = [int(pid) for pid, parent in (line.split() for line in children.splitlines())
                          if int(parent) == process.pid]
            self.assertTrue(child_pids, "Music should run in an isolated child process")
            self.stop_promptly(process)
            for pid in child_pids:
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
        self.assert_restart_answer()


if __name__ == "__main__":
    unittest.main(verbosity=2)
