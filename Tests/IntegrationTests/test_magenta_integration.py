#!/usr/bin/env python3
"""Generate real Magenta audio to check the published MLX function format."""

import os
import sys
from pathlib import Path

from test_all_models_integration import MLXtraIntegrationTest
from runtime_layout import prepared_music_runtime
import test_all_models_integration as integration


def main() -> bool:
    model_name = os.environ.get("MLXTRA_INTEGRATION_MAGENTA_MODEL", "mrt2_small")
    if model_name not in {"mrt2_small", "mrt2_base"}:
        print(f"ERROR: Unsupported Magenta model: {model_name}")
        return False
    checkpoints = Path(
        os.environ.get("MAGENTA_RT_CHECKPOINTS_DIR")
        or integration.ACESTEP_CHECKPOINTS_DIR
    )
    model_home = checkpoints / "magenta-realtime-2" / model_name
    required = [
        model_home / "models" / model_name / f"{model_name}.mlxfn",
        model_home / "models" / model_name / f"{model_name}_state.safetensors",
        *(model_home / "resources/musiccoca" / name for name in (
            "text_encoder.tflite", "mapper.tflite", "spm.model",
            "pretrained_vector_quantizer.tflite",
        )),
    ]
    missing = [str(path) for path in required if not integration.path_has_content(path)]
    if missing:
        status = "ERROR" if integration.REQUIRE_ALL_MODELS else "SKIP"
        print(f"{status}: Magenta model files missing; downloads disabled:\n" + "\n".join(missing))
        return not integration.REQUIRE_ALL_MODELS

    class MagentaTest(MLXtraIntegrationTest):
        def get_bridge_env(self) -> dict:
            env = super().get_bridge_env()
            env["MAGENTA_RT_CHECKPOINTS_DIR"] = str(checkpoints)
            env["MAGENTA_RT_PYTHON"] = str(integration.MUSIC_RUNTIME / "magenta-venv/bin/python")
            env["HF_HUB_OFFLINE"] = "1"
            return env

    test = MagentaTest()
    request_id = "integration-magenta-generate"
    output_dir = Path(os.environ.get("MLXTRA_INTEGRATION_OUTPUT_DIR") or integration.GENERATED_MUSIC_DIR)
    request = {
        "type": "music.generate",
        "model": f"google/magenta-realtime-2/{model_name}",
        "request_id": request_id,
        "prompt": "Gentle acoustic guitar and piano instrumental",
        "output_dir": str(output_dir),
        "parameters": {"duration": 2, "seed": 42},
    }
    with prepared_music_runtime(integration.RUNTIME, integration.MUSIC_RUNTIME):
        messages, success = test.send_request_to_bridge(request, timeout=600)
    if not success or not test.require_no_error(messages):
        return False
    generated = test.require_message(messages, "audio.generated", request_id)
    if not generated or not test.require_completion(messages, request_id):
        return False
    if not test.validate_wav(generated.get("path", ""), minimum_duration=1.0, expected_sample_rate=48000):
        return False
    print("PASS: Magenta compiled-model loading and music generation")
    return True


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
