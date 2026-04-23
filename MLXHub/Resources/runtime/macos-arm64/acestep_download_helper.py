#!/usr/bin/env python3
"""
ACE-Step Model Download Helper for MLXHub

This script properly triggers ACE-Step's model download mechanism,
which handles the HF cache and checkpoint directory structure correctly.

Usage: acestep_download_helper.py <repo_id> <local_dir>
"""

import sys
import contextlib
import json
import time
from pathlib import Path

JSON_OUTPUT = sys.stdout


def log(msg):
    print(f"[ACE-Step Download Helper] {msg}", file=sys.stderr, flush=True)


def send_json(obj):
    print(json.dumps(obj), file=JSON_OUTPUT, flush=True)


def emit(event):
    print(json.dumps(event), file=JSON_OUTPUT, flush=True)


def progress_kind(unit, description):
    normalized_unit = str(unit or "").lower()
    normalized_description = str(description or "").lower()

    if normalized_unit == "b":
        return "bytes"
    if normalized_unit in {"it", "file", "files"} or normalized_description.startswith("fetching "):
        return "files"
    return "items"


def progress_status(raw_status, kind):
    if kind == "bytes":
        return {
            "started": "Preparing download",
            "downloading": "Downloading",
            "finished": "Download complete",
        }.get(raw_status, raw_status)

    if kind == "files":
        return {
            "started": "Preparing files",
            "downloading": "Fetching files",
            "finished": "Files fetched",
        }.get(raw_status, raw_status)

    return {
        "started": "Preparing",
        "downloading": "Working",
        "finished": "Finishing",
    }.get(raw_status, raw_status)


def install_huggingface_progress_hook():
    import huggingface_hub
    from tqdm.auto import tqdm

    original_snapshot_download = huggingface_hub.snapshot_download

    class JsonTqdm(tqdm):
        def __init__(self, *args, **kwargs):
            self._last_emit = 0.0
            super().__init__(*args, **kwargs)
            self._emit_progress("started")

        def update(self, n=1):
            result = super().update(n)
            now = time.time()
            if now - self._last_emit >= 0.25 or (self.total and self.n >= self.total):
                self._last_emit = now
                self._emit_progress("downloading")
            return result

        def close(self):
            self._emit_progress("finished")
            return super().close()

        def _emit_progress(self, status):
            total = int(self.total) if self.total else None
            downloaded = int(self.n or 0)
            percent = (downloaded / total * 100.0) if total else None
            unit = str(self.unit or "")
            description = str(self.desc or "")
            kind = progress_kind(unit, description)

            emit(
                {
                    "type": "download.progress",
                    "status": progress_status(status, kind),
                    "description": description,
                    "unit": unit,
                    "progress_kind": kind,
                    "downloaded": downloaded,
                    "total": total,
                    "percent": percent,
                }
            )

    def snapshot_download_with_progress(*args, **kwargs):
        kwargs.setdefault("tqdm_class", JsonTqdm)
        return original_snapshot_download(*args, **kwargs)

    huggingface_hub.snapshot_download = snapshot_download_with_progress


def main():
    if len(sys.argv) < 3:
        emit({"type": "download.error", "message": "Usage: acestep_download_helper.py <repo_id> <local_dir>"})
        sys.exit(1)

    repo_id = sys.argv[1]
    local_dir = Path(sys.argv[2]).resolve()

    emit({"type": "download.started", "repo_id": repo_id})
    log(f"Starting download: repo_id={repo_id}, local_dir={local_dir}")

    try:
        install_huggingface_progress_hook()

        with contextlib.redirect_stdout(sys.stderr):
            from acestep.model_downloader import (
                check_main_model_exists,
                ensure_main_model,
                MAIN_MODEL_COMPONENTS,
            )

        # Check if already exists
        with contextlib.redirect_stdout(sys.stderr):
            already_downloaded = check_main_model_exists(local_dir)
        if already_downloaded:
            emit({"type": "download.complete", "repo_id": repo_id, "path": str(local_dir)})
            send_json({"type": "download.status", "status": "already_downloaded", "path": str(local_dir)})
            log("Model already exists")
            sys.exit(0)

        # Download using ACE-Step's proper mechanism
        emit(
            {
                "type": "download.progress",
                "status": "Downloading",
                "description": "Downloading ACE-Step checkpoints",
                "progress_kind": "activity",
            }
        )
        log("Model not found, triggering download...")
        with contextlib.redirect_stdout(sys.stderr):
            success, msg = ensure_main_model(local_dir)

        if success:
            # Verify using ACE-Step's strict weight-file check
            emit(
                {
                    "type": "download.progress",
                    "status": "Verifying",
                    "description": "Checking ACE-Step checkpoint components",
                    "progress_kind": "activity",
                }
            )
            with contextlib.redirect_stdout(sys.stderr):
                verified = check_main_model_exists(local_dir)
            if verified:
                send_json(
                    {
                        "type": "download.status",
                        "status": "downloaded",
                        "path": str(local_dir),
                        "components": MAIN_MODEL_COMPONENTS,
                    }
                )
                emit({"type": "download.complete", "repo_id": repo_id, "path": str(local_dir)})
                log("Download completed successfully")
                sys.exit(0)
            else:
                emit(
                    {
                        "type": "download.error",
                        "message": "Download reported success but weight files missing or incomplete",
                    }
                )
                log("Download failed: weight files missing or incomplete")
                sys.exit(1)
        else:
            emit({"type": "download.error", "message": f"Download failed: {msg}"})
            log(f"Download failed: {msg}")
            sys.exit(1)

    except Exception as e:
        import traceback

        emit({"type": "download.error", "message": str(e), "traceback": traceback.format_exc()})
        log(f"Exception: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
