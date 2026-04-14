#!/usr/bin/env python3
"""
ACE-Step Model Download Helper for MLXHub

This script properly triggers ACE-Step's model download mechanism,
which handles the HF cache and checkpoint directory structure correctly.

Usage: acestep_download_helper.py <repo_id> <local_dir>
"""

import sys
import json
from pathlib import Path


def log(msg):
    print(f"[ACE-Step Download Helper] {msg}", flush=True)


def send_json(obj):
    print(json.dumps(obj), flush=True)


def main():
    if len(sys.argv) < 3:
        send_json({"error": "Usage: acestep_download_helper.py <repo_id> <local_dir>"})
        sys.exit(1)

    repo_id = sys.argv[1]
    local_dir = Path(sys.argv[2]).resolve()

    log(f"Starting download: repo_id={repo_id}, local_dir={local_dir}")

    try:
        from acestep.model_downloader import (
            check_main_model_exists,
            ensure_main_model,
            MAIN_MODEL_COMPONENTS,
        )

        # Check if already exists
        if check_main_model_exists(local_dir):
            send_json({"status": "already_downloaded", "path": str(local_dir)})
            log("Model already exists")
            sys.exit(0)

        # Download using ACE-Step's proper mechanism
        log("Model not found, triggering download...")
        success, msg = ensure_main_model(local_dir)

        if success:
            # Verify all components exist
            all_exist = True
            for component in MAIN_MODEL_COMPONENTS:
                component_path = local_dir / component
                if not component_path.exists():
                    log(f"Component missing: {component_path}")
                    all_exist = False

            if all_exist:
                send_json(
                    {
                        "status": "downloaded",
                        "path": str(local_dir),
                        "components": MAIN_MODEL_COMPONENTS,
                    }
                )
                log("Download completed successfully")
                sys.exit(0)
            else:
                send_json(
                    {
                        "error": f"Download reported success but components missing: {msg}"
                    }
                )
                log(f"Download failed: components missing")
                sys.exit(1)
        else:
            send_json({"error": f"Download failed: {msg}"})
            log(f"Download failed: {msg}")
            sys.exit(1)

    except Exception as e:
        import traceback

        send_json({"error": str(e), "traceback": traceback.format_exc()})
        log(f"Exception: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
