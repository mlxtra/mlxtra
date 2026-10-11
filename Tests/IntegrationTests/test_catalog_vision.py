#!/usr/bin/env python3
"""Offline chat and image-understanding checks for catalog vision models.

Select models with MLXTRA_INTEGRATION_VISION_MODELS (comma-separated IDs).
HF_HUB_CACHE selects a cache; MLXTRA_REQUIRE_ALL_MODELS=1 fails on missing
weights. This test never downloads models. Results are saved to
MLXTRA_INTEGRATION_OUTPUT_DIR, or .build/catalog-vision-tests.
"""

import json
import os
import struct
import unittest
import zlib
from pathlib import Path

import test_all_models_integration as integration


class OfflineBridge(integration.MLXtraIntegrationTest):
    def get_bridge_env(self):
        env = super().get_bridge_env()
        env.update(
            HF_HUB_CACHE=str(integration.HF_CACHE),
            HF_HUB_OFFLINE="1",
            TRANSFORMERS_OFFLINE="1",
        )
        return env


def write_color_fixture(path, rgb):
    """Write a 512×512 RGB PNG without a host imaging dependency."""
    def chunk(kind, data):
        checksum = zlib.crc32(kind + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", checksum)

    size = 512
    pixels = (b"\0" + bytes(rgb) * size) * size
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(pixels))
        + chunk(b"IEND", b"")
    )


class CatalogVisionTests(unittest.TestCase):
    def test_catalog_chat_and_colors(self):
        catalog = json.loads(
            (integration.REPO_ROOT / "MLXtra/Resources/model-catalog.json").read_text()
        )
        models = [model["modelId"] for model in catalog["models"] if model["backend"] == "vlm"]
        selected = os.environ.get("MLXTRA_INTEGRATION_VISION_MODELS")
        if selected:
            requested = {model.strip() for model in selected.split(",") if model.strip()}
            self.assertFalse(requested - set(models), "Selection contains unknown catalog model IDs")
            models = [model for model in models if model in requested]
        if os.environ.get("HF_HUB_CACHE"):
            integration.HF_CACHE = Path(os.environ["HF_HUB_CACHE"])
        output = Path(os.environ.get("MLXTRA_INTEGRATION_OUTPUT_DIR") or integration.REPO_ROOT / ".build/catalog-vision-tests")
        output.mkdir(parents=True, exist_ok=True)
        fixtures = {}
        for color, rgb in {"red": (255, 0, 0), "blue": (0, 0, 255)}.items():
            fixtures[color] = output / (color + ".png")
            write_color_fixture(fixtures[color], rgb)

        bridge = OfflineBridge()
        for model in models:
            with self.subTest(model=model):
                if not integration.hf_snapshot_is_complete(model):
                    if integration.REQUIRE_ALL_MODELS:
                        self.fail("Missing complete cached weights for " + model)
                    self.skipTest("Missing cached weights; downloads disabled: " + model)
                requests = [{"type": "init", "model_id": model, "backend": "vlm"}]
                expectations = {"catalog-chat": "4", "catalog-red": "red", "catalog-blue": "blue"}
                for request_id in expectations:
                    request = {
                        "type": "chat.completions", "model": model, "request_id": request_id,
                        "messages": [{"role": "user", "content": "What is 2 plus 2? Reply with just the number."}],
                        "max_tokens": 100, "temperature": 0,
                        "chat_template_kwargs": {"enable_thinking": False},
                    }
                    if request_id != "catalog-chat":
                        color = expectations[request_id]
                        request["images"] = [str(fixtures[color].resolve())]
                        request["messages"][0]["content"] = "What is the dominant color of this image? Answer with one color."
                    requests.append(request)
                messages, success = bridge.run_bridge_session(requests, timeout=1200)
                (output / (model.replace("/", "--") + ".json")).write_text(
                    json.dumps({"success": success, "messages": messages}, indent=2)
                )
                self.assertTrue(success, "Bridge session did not complete")
                self.assertTrue(bridge.require_no_error(messages))
                for request_id, expected in expectations.items():
                    with self.subTest(model=model, request=request_id):
                        self.assertTrue(bridge.require_completion(messages, request_id))
                        answer = "".join(
                            event.get("choices", [{}])[0].get("delta", {}).get("content", "")
                            for event in messages
                            if event.get("type") == "chat.completion.chunk" and event.get("request_id") == request_id
                        ).strip().lower().strip(" .!\n")
                        print(model, request_id, repr(answer), flush=True)
                        self.assertEqual(answer, expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
