#!/usr/bin/env python3
import hashlib
import json
import os
import sys
import time
from pathlib import Path

from huggingface_hub import HfApi, snapshot_download
from tqdm.auto import tqdm

AGGREGATE_TOTAL_BYTES = None
DEFAULT_HASH_VERIFY_MAX_BYTES = 64 * 1024 * 1024


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


def repo_file_manifest(repo_id):
    manifest = []
    api = HfApi()
    for item in api.list_repo_tree(repo_id=repo_id, recursive=True, expand=True):
        item_type = str(getattr(item, "type", "") or "").lower()
        class_name = type(item).__name__.lower()
        if item_type in {"directory", "folder", "tree"} or "folder" in class_name:
            continue

        item_path = getattr(item, "path", None)
        if not item_path:
            continue

        size = getattr(item, "size", None)
        lfs = getattr(item, "lfs", None)
        if size is None and isinstance(lfs, dict):
            size = lfs.get("size")
        elif size is None and lfs is not None:
            size = getattr(lfs, "size", None)

        manifest.append(
            {
                "path": item_path,
                "size": int(size) if size is not None else None,
                "sha256": stable_lfs_sha256(lfs),
            }
        )

    return manifest


def stable_lfs_sha256(lfs):
    if not lfs:
        return None

    candidates = []
    if isinstance(lfs, dict):
        candidates.extend([lfs.get("sha256"), lfs.get("oid")])
    else:
        candidates.extend([getattr(lfs, "sha256", None), getattr(lfs, "oid", None)])

    for candidate in candidates:
        if not candidate:
            continue
        normalized = str(candidate).lower()
        if len(normalized) == 64 and all(char in "0123456789abcdef" for char in normalized):
            return normalized

    return None


def manifest_total_bytes(manifest):
    total = sum(item["size"] for item in manifest if item.get("size") is not None)
    return total or None


def hash_verify_max_bytes():
    raw_value = os.environ.get("MLXTRA_HASH_VERIFY_MAX_BYTES")
    if raw_value is None:
        return DEFAULT_HASH_VERIFY_MAX_BYTES

    try:
        return max(int(raw_value), 0)
    except ValueError:
        return DEFAULT_HASH_VERIFY_MAX_BYTES


def should_hash_file(size):
    if os.environ.get("MLXTRA_SKIP_LARGE_FILE_HASHES") == "1":
        return size <= hash_verify_max_bytes()
    return True


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def verify_snapshot(snapshot_path, manifest):
    root = Path(snapshot_path)
    missing = []
    size_mismatches = []
    hash_mismatches = []
    hash_checked = 0
    hash_skipped = 0

    for item in manifest:
        candidate = root / item["path"]
        try:
            resolved = candidate.resolve(strict=True)
            stat = resolved.stat()
        except OSError:
            missing.append(item["path"])
            continue

        if not resolved.is_file():
            missing.append(item["path"])
            continue

        expected_size = item.get("size")
        if expected_size is not None and stat.st_size != expected_size:
            size_mismatches.append(
                {
                    "path": item["path"],
                    "expected": expected_size,
                    "actual": stat.st_size,
                }
            )
            continue

        expected_sha256 = item.get("sha256")
        if not expected_sha256:
            continue

        if should_hash_file(stat.st_size):
            actual_sha256 = file_sha256(resolved)
            hash_checked += 1
            if actual_sha256 != expected_sha256:
                hash_mismatches.append(
                    {
                        "path": item["path"],
                        "expected": expected_sha256,
                        "actual": actual_sha256,
                    }
                )
        else:
            hash_skipped += 1

    if missing or size_mismatches or hash_mismatches:
        details = []
        if missing:
            details.append(f"missing files: {', '.join(missing[:5])}")
        if size_mismatches:
            formatted = [
                f"{item['path']} expected {item['expected']} bytes got {item['actual']}"
                for item in size_mismatches[:5]
            ]
            details.append("size mismatches: " + "; ".join(formatted))
        if hash_mismatches:
            formatted = [
                f"{item['path']} expected sha256 {item['expected']} got {item['actual']}"
                for item in hash_mismatches[:5]
            ]
            details.append("hash mismatches: " + "; ".join(formatted))
        raise RuntimeError("Downloaded snapshot is incomplete (" + "; ".join(details) + ")")

    return {
        "file_count": len(manifest),
        "hash_count": hash_checked,
        "hash_skipped": hash_skipped,
    }


def is_aggregate_byte_progress(kind, description):
    normalized_description = str(description or "").lower()
    return kind == "bytes" and AGGREGATE_TOTAL_BYTES and "downloading" in normalized_description


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
        unit = str(self.unit or "")
        description = str(self.desc or "")
        kind = progress_kind(unit, description)
        percent = None
        percent_reliable = False
        progress_scope = None

        if is_aggregate_byte_progress(kind, description):
            total = int(AGGREGATE_TOTAL_BYTES)
            downloaded = min(downloaded, total)
            percent = (downloaded / total * 100.0) if total else None
            percent_reliable = percent is not None
            progress_scope = "aggregate"

        event = {
            "type": "download.progress",
            "status": progress_status(status, kind),
            "description": description,
            "unit": unit,
            "progress_kind": kind,
            "downloaded": downloaded,
            "total": total,
            "percent": percent,
            "percent_reliable": percent_reliable,
        }
        if progress_scope:
            event["progress_scope"] = progress_scope
        emit(event)


def main():
    if len(sys.argv) < 2:
        emit({"type": "download.error", "message": "Usage: hf_download_helper.py <repo_id>"})
        sys.exit(1)

    repo_id = sys.argv[1]
    emit({"type": "download.started", "repo_id": repo_id})

    emit(
        {
            "type": "download.progress",
            "status": "Preparing download",
            "description": "Checking download size",
            "progress_kind": "activity",
        }
    )

    manifest = repo_file_manifest(repo_id)
    if not manifest:
        raise RuntimeError(f"Could not fetch repository manifest for {repo_id}")

    global AGGREGATE_TOTAL_BYTES
    AGGREGATE_TOTAL_BYTES = manifest_total_bytes(manifest)
    if AGGREGATE_TOTAL_BYTES:
        emit(
            {
                "type": "download.progress",
                "status": "Preparing download",
                "description": "Download size calculated",
                "unit": "B",
                "progress_kind": "bytes",
                "progress_scope": "aggregate",
                "downloaded": 0,
                "total": AGGREGATE_TOTAL_BYTES,
                "percent": 0.0,
                "percent_reliable": True,
            }
        )

    path = snapshot_download(repo_id=repo_id, tqdm_class=JsonTqdm)

    emit(
        {
            "type": "download.progress",
            "status": "Verifying files",
            "description": "Checking local snapshot against repository manifest",
            "progress_kind": "activity",
        }
    )
    verified = verify_snapshot(path, manifest)
    emit(
        {
            "type": "download.verified",
            "repo_id": repo_id,
            "path": path,
            "file_count": verified["file_count"],
            "hash_count": verified["hash_count"],
            "hash_skipped": verified["hash_skipped"],
        }
    )
    emit({"type": "download.complete", "repo_id": repo_id, "path": path})


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        emit({"type": "download.error", "message": str(exc)})
        raise
