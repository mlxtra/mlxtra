#!/usr/bin/env python3
import json
import sys
import time

from huggingface_hub import snapshot_download
from tqdm.auto import tqdm


def emit(event):
    print(json.dumps(event), flush=True)


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


def main():
    if len(sys.argv) < 2:
        emit({"type": "download.error", "message": "Usage: hf_download_helper.py <repo_id>"})
        sys.exit(1)

    repo_id = sys.argv[1]
    emit({"type": "download.started", "repo_id": repo_id})

    path = snapshot_download(repo_id=repo_id, tqdm_class=JsonTqdm)

    emit({"type": "download.complete", "repo_id": repo_id, "path": path})


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        emit({"type": "download.error", "message": str(exc)})
        raise
