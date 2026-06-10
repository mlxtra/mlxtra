#!/usr/bin/env python3
"""Resolve and prepare MLXtra's split base and music runtimes for tests."""

from __future__ import annotations

import os
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator


def base_runtime_is_valid(path: Path) -> bool:
    return all(
        (path / relative_path).exists()
        for relative_path in (
            "venv/bin/python",
            "python/Frameworks/Versions/3.12",
            "runtime-manifest.json",
        )
    )


def music_runtime_is_valid(path: Path) -> bool:
    return all(
        (path / relative_path).exists()
        for relative_path in (
            "acestep-venv/bin/python",
            "acestep_download_helper.py",
            "runtime-music-manifest.json",
        )
    )


def resolve_base_runtime(resources: Path, app_support: Path) -> Path:
    candidates: list[Path] = []
    override = os.environ.get("MLXTRA_RUNTIME_DIR")
    if override:
        candidates.append(Path(override))
    candidates.extend(
        (
            app_support / "runtimes/macos-arm64/current",
            resources / "runtime/macos-arm64",
        )
    )

    for candidate in candidates:
        if base_runtime_is_valid(candidate):
            return candidate
    return candidates[-1]


def resolve_music_runtime(base_runtime: Path, resources: Path) -> Path:
    candidates: list[Path] = []
    override = os.environ.get("MLXTRA_MUSIC_RUNTIME_DIR")
    if override:
        candidates.append(Path(override))
    candidates.extend(
        (
            base_runtime,
            base_runtime.parent / "music-macos-arm64",
            resources / "runtime/music-macos-arm64",
        )
    )

    for candidate in candidates:
        if music_runtime_is_valid(candidate):
            return candidate
    return candidates[-1]


@contextmanager
def prepared_music_runtime(
    base_runtime: Path, music_runtime: Path
) -> Iterator[None]:
    """Temporarily expose base runtime dependencies beside a split music runtime."""
    created_links: list[Path] = []

    if music_runtime.resolve() != base_runtime.resolve():
        for name in ("python", "shared"):
            source = base_runtime / name
            destination = music_runtime / name
            if not source.exists() or destination.exists() or destination.is_symlink():
                continue
            destination.symlink_to(source, target_is_directory=True)
            created_links.append(destination)

    try:
        yield
    finally:
        for link in reversed(created_links):
            if link.is_symlink():
                link.unlink()
