#!/usr/bin/env python3
"""Validate MLXtra release channel and model catalog metadata."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys
from typing import Any
from urllib.parse import urlparse


KNOWN_MODALITIES = {"vision", "chat", "image", "audio", "speech", "music"}
KNOWN_BACKENDS = {"vlm", "llm", "image", "audio", "music"}
KNOWN_SOURCE_TYPES = {"hugging_face_snapshot", "component_bundle"}
KNOWN_DOWNLOAD_HELPERS = {"ace_step"}
KNOWN_RUNTIME_COMPONENTS = {"base", "music"}
KNOWN_PARAMETER_TYPES = {"decimal", "integer", "boolean", "option", "text"}
KNOWN_AVAILABILITY = {"visible", "hidden", "requires_hf_access"}
KNOWN_IMAGE_PROMPT_ADAPTERS = {"ideogram4_json"}
VERSION_RE = re.compile(r"^[0-9]+(?:\.[0-9]+){1,3}(?:[-.][0-9A-Za-z]+)?$")
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")


class Validator:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, message: str) -> None:
        self.errors.append(message)

    def warning(self, message: str) -> None:
        self.warnings.append(message)

    def require(self, condition: bool, message: str) -> None:
        if not condition:
            self.error(message)


def load_json(path: pathlib.Path, validator: Validator) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        validator.error(f"{path} does not exist")
    except json.JSONDecodeError as error:
        validator.error(f"{path} is not valid JSON: {error}")
    except OSError as error:
        validator.error(f"{path} could not be read: {error}")
    return None


def sha256_hex(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_non_empty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def validate_version(value: Any, field: str, validator: Validator) -> None:
    validator.require(is_non_empty_string(value), f"{field} must be a non-empty string")
    if isinstance(value, str):
        validator.require(bool(VERSION_RE.match(value)), f"{field} has unsupported version format: {value}")


def compare_versions(left: str, right: str) -> int:
    def tokens(value: str) -> list[Any]:
        parts: list[Any] = []
        for part in re.split(r"[.-]", value):
            parts.append(int(part) if part.isdigit() else part)
        return parts

    left_tokens = tokens(left)
    right_tokens = tokens(right)
    max_count = max(len(left_tokens), len(right_tokens))
    for index in range(max_count):
        left_value = left_tokens[index] if index < len(left_tokens) else 0
        right_value = right_tokens[index] if index < len(right_tokens) else 0
        if left_value == right_value:
            continue
        if isinstance(left_value, int) and isinstance(right_value, int):
            return -1 if left_value < right_value else 1
        return -1 if str(left_value) < str(right_value) else 1
    return 0


def validate_url(value: Any, field: str, validator: Validator) -> None:
    validator.require(is_non_empty_string(value), f"{field} must be a non-empty URL string")
    if not isinstance(value, str):
        return

    parsed = urlparse(value)
    if parsed.scheme == "file":
        validator.require(bool(parsed.path), f"{field} file URL is missing a path")
    else:
        validator.require(parsed.scheme == "https", f"{field} must use https for release metadata")
        validator.require(bool(parsed.netloc), f"{field} is missing a host")


def require_number(value: Any, field: str, validator: Validator, minimum: float | None = None) -> None:
    validator.require(isinstance(value, (int, float)) and not isinstance(value, bool), f"{field} must be a number")
    if isinstance(value, (int, float)) and minimum is not None:
        validator.require(value >= minimum, f"{field} must be >= {minimum}")


def require_int(value: Any, field: str, validator: Validator, minimum: int | None = None) -> None:
    validator.require(isinstance(value, int) and not isinstance(value, bool), f"{field} must be an integer")
    if isinstance(value, int) and minimum is not None:
        validator.require(value >= minimum, f"{field} must be >= {minimum}")


def validate_parameter(parameter: dict[str, Any], path: str, validator: Validator) -> str | None:
    key = parameter.get("key")
    validator.require(is_non_empty_string(key), f"{path}.key must be a non-empty string")
    validator.require(is_non_empty_string(parameter.get("label")), f"{path}.label must be a non-empty string")

    param_type = parameter.get("type")
    validator.require(param_type in KNOWN_PARAMETER_TYPES, f"{path}.type is unsupported: {param_type}")
    validator.require("defaultValue" in parameter, f"{path}.defaultValue is required")
    validator.require(isinstance(parameter.get("defaultValue"), str), f"{path}.defaultValue must be a string")

    if "range" in parameter:
        range_value = parameter["range"]
        validator.require(isinstance(range_value, dict), f"{path}.range must be an object")
        if isinstance(range_value, dict):
            require_number(range_value.get("min"), f"{path}.range.min", validator)
            require_number(range_value.get("max"), f"{path}.range.max", validator)
            if isinstance(range_value.get("min"), (int, float)) and isinstance(range_value.get("max"), (int, float)):
                validator.require(range_value["min"] <= range_value["max"], f"{path}.range min must be <= max")

    require_number(parameter.get("step", 1), f"{path}.step", validator, minimum=0)
    validator.require(isinstance(parameter.get("options", []), list), f"{path}.options must be an array")
    validator.require(isinstance(parameter.get("isAdvanced", False), bool), f"{path}.isAdvanced must be a boolean")

    default_value = parameter.get("defaultValue")
    if isinstance(default_value, str):
        if param_type == "decimal":
            try:
                float(default_value)
            except ValueError:
                validator.error(f"{path}.defaultValue must be decimal-compatible")
        elif param_type == "integer":
            try:
                int(float(default_value))
            except ValueError:
                validator.error(f"{path}.defaultValue must be integer-compatible")
        elif param_type == "boolean":
            validator.require(
                default_value.lower() in {"true", "false", "yes", "no", "1", "0"},
                f"{path}.defaultValue must be boolean-compatible",
            )
        elif param_type == "option":
            options = parameter.get("options", [])
            validator.require(default_value in options, f"{path}.defaultValue must be present in options")

    return key if isinstance(key, str) else None


def validate_model(model: dict[str, Any], index: int, validator: Validator) -> dict[str, Any]:
    path = f"models[{index}]"
    for field in ("id", "name", "subtitle", "modelId", "icon"):
        validator.require(is_non_empty_string(model.get(field)), f"{path}.{field} must be a non-empty string")

    modality = model.get("modality")
    validator.require(modality in KNOWN_MODALITIES, f"{path}.modality is unsupported: {modality}")

    backend = model.get("backend")
    validator.require(backend in KNOWN_BACKENDS, f"{path}.backend is unsupported: {backend}")

    availability = model.get("availability", "visible")
    validator.require(availability in KNOWN_AVAILABILITY, f"{path}.availability is unsupported: {availability}")

    capabilities = model.get("capabilities")
    validator.require(isinstance(capabilities, list), f"{path}.capabilities must be an array")
    if isinstance(capabilities, list):
        for cap_index, capability in enumerate(capabilities):
            validator.require(is_non_empty_string(capability), f"{path}.capabilities[{cap_index}] must be a non-empty string")

    require_int(model.get("maxContextWindow"), f"{path}.maxContextWindow", validator, minimum=0)
    require_int(model.get("defaultMaxTokens"), f"{path}.defaultMaxTokens", validator, minimum=0)
    if isinstance(model.get("maxContextWindow"), int) and isinstance(model.get("defaultMaxTokens"), int):
        if model["maxContextWindow"] > 0:
            validator.require(
                model["defaultMaxTokens"] <= model["maxContextWindow"],
                f"{path}.defaultMaxTokens must be <= maxContextWindow",
            )
    require_number(model.get("downloadSizeGB"), f"{path}.downloadSizeGB", validator, minimum=0)
    if model.get("estimatedMemoryGB") is not None:
        require_number(model.get("estimatedMemoryGB"), f"{path}.estimatedMemoryGB", validator, minimum=0)

    source = model.get("source")
    validator.require(isinstance(source, dict), f"{path}.source must be an object")
    if isinstance(source, dict):
        source_type = source.get("type")
        validator.require(source_type in KNOWN_SOURCE_TYPES, f"{path}.source.type is unsupported: {source_type}")
        if source_type == "hugging_face_snapshot":
            validator.require(is_non_empty_string(source.get("repo")), f"{path}.source.repo is required for HF snapshots")
            validator.require(is_non_empty_string(source.get("revision")), f"{path}.source.revision is required for HF snapshots")
        if source_type == "component_bundle":
            validator.require(is_non_empty_string(source.get("repo")), f"{path}.source.repo is required for component bundles")
            components = source.get("components")
            validator.require(isinstance(components, list) and len(components) > 0, f"{path}.source.components must be non-empty")
            if isinstance(components, list):
                for component_index, component in enumerate(components):
                    validator.require(
                        is_non_empty_string(component),
                        f"{path}.source.components[{component_index}] must be a non-empty string",
                    )
            helper = source.get("helper")
            if helper is not None:
                validator.require(helper in KNOWN_DOWNLOAD_HELPERS, f"{path}.source.helper is unsupported: {helper}")
            storage_subdirectory = source.get("storageSubdirectory")
            if storage_subdirectory is not None:
                validator.require(
                    is_non_empty_string(storage_subdirectory)
                    and not storage_subdirectory.startswith("/")
                    and ".." not in storage_subdirectory.split("/"),
                    f"{path}.source.storageSubdirectory must be a safe relative path",
                )

    runtime = model.get("runtime")
    validator.require(isinstance(runtime, dict), f"{path}.runtime must be an object")
    runtime_api = None
    min_runtime = None
    runtime_component = "base"
    if isinstance(runtime, dict):
        min_runtime = runtime.get("minVersion")
        validate_version(min_runtime, f"{path}.runtime.minVersion", validator)
        runtime_api = runtime.get("compatibilityApi")
        require_int(runtime_api, f"{path}.runtime.compatibilityApi", validator, minimum=1)
        runtime_component = runtime.get("component", "base")
        validator.require(
            runtime_component in KNOWN_RUNTIME_COMPONENTS,
            f"{path}.runtime.component is unsupported: {runtime_component}",
        )

    runtime_options = model.get("runtimeOptions")
    if runtime_options is not None:
        validator.require(isinstance(runtime_options, dict), f"{path}.runtimeOptions must be an object")
        if isinstance(runtime_options, dict):
            mflux_options = runtime_options.get("mflux")
            if mflux_options is not None:
                validator.require(isinstance(mflux_options, dict), f"{path}.runtimeOptions.mflux must be an object")
                if isinstance(mflux_options, dict):
                    config = mflux_options.get("config")
                    validator.require(is_non_empty_string(config), f"{path}.runtimeOptions.mflux.config must be a non-empty string")
                    text_class = mflux_options.get("textToImageClass")
                    edit_class = mflux_options.get("editClass")
                    validator.require(is_non_empty_string(text_class), f"{path}.runtimeOptions.mflux.textToImageClass must be a non-empty string")
                    if edit_class is not None:
                        validator.require(is_non_empty_string(edit_class), f"{path}.runtimeOptions.mflux.editClass must be a non-empty string")
                    if isinstance(capabilities, list) and "image-editing" in capabilities:
                        validator.require(is_non_empty_string(edit_class), f"{path}.runtimeOptions.mflux.editClass is required for image-editing models")
                    quantize = mflux_options.get("quantize")
                    if quantize is not None:
                        require_int(quantize, f"{path}.runtimeOptions.mflux.quantize", validator, minimum=1)
                    if backend != "image":
                        validator.error(f"{path}.runtimeOptions.mflux is only supported for image backend models")
            chat_template = runtime_options.get("chatTemplate")
            if chat_template is not None:
                validator.require(isinstance(chat_template, dict), f"{path}.runtimeOptions.chatTemplate must be an object")
                if isinstance(chat_template, dict):
                    parameter_kwargs = chat_template.get("parameterKwargs", {})
                    validator.require(isinstance(parameter_kwargs, dict), f"{path}.runtimeOptions.chatTemplate.parameterKwargs must be an object")
                    if isinstance(parameter_kwargs, dict):
                        for kwarg, parameter_key in parameter_kwargs.items():
                            validator.require(is_non_empty_string(kwarg), f"{path}.runtimeOptions.chatTemplate.parameterKwargs contains an empty kwarg")
                            validator.require(is_non_empty_string(parameter_key), f"{path}.runtimeOptions.chatTemplate.parameterKwargs.{kwarg} must be a parameter key")
            audio_options = runtime_options.get("audio")
            if audio_options is not None:
                validator.require(isinstance(audio_options, dict), f"{path}.runtimeOptions.audio must be an object")
                if isinstance(audio_options, dict):
                    validator.require(is_non_empty_string(audio_options.get("adapter")), f"{path}.runtimeOptions.audio.adapter must be a non-empty string")
                    if audio_options.get("defaultVoice") is not None:
                        validator.require(is_non_empty_string(audio_options.get("defaultVoice")), f"{path}.runtimeOptions.audio.defaultVoice must be a non-empty string")
                    language_by_prefix = audio_options.get("languageByVoicePrefix", {})
                    validator.require(isinstance(language_by_prefix, dict), f"{path}.runtimeOptions.audio.languageByVoicePrefix must be an object")
                    if isinstance(language_by_prefix, dict):
                        for prefix, lang_code in language_by_prefix.items():
                            validator.require(is_non_empty_string(prefix), f"{path}.runtimeOptions.audio.languageByVoicePrefix contains an empty prefix")
                            validator.require(is_non_empty_string(lang_code), f"{path}.runtimeOptions.audio.languageByVoicePrefix.{prefix} must be a non-empty string")
                    if backend != "audio":
                        validator.error(f"{path}.runtimeOptions.audio is only supported for audio backend models")

    prompting = model.get("prompting")
    if prompting is not None:
        validator.require(isinstance(prompting, dict), f"{path}.prompting must be an object")
        if isinstance(prompting, dict):
            image_adapter = prompting.get("imageAdapter")
            if image_adapter is not None:
                validator.require(
                    image_adapter in KNOWN_IMAGE_PROMPT_ADAPTERS,
                    f"{path}.prompting.imageAdapter is unsupported: {image_adapter}",
                )
                if backend != "image":
                    validator.error(f"{path}.prompting.imageAdapter is only supported for image backend models")

    ranking = model.get("ranking")
    validator.require(isinstance(ranking, dict), f"{path}.ranking must be an object")
    if isinstance(ranking, dict):
        require_int(ranking.get("quality"), f"{path}.ranking.quality", validator, minimum=0)
        require_int(ranking.get("speed"), f"{path}.ranking.speed", validator, minimum=0)
        if ranking.get("defaultForMemoryGB") is not None:
            require_number(ranking.get("defaultForMemoryGB"), f"{path}.ranking.defaultForMemoryGB", validator, minimum=1)
        preferred_chip_names = ranking.get("preferredChipNames", [])
        validator.require(isinstance(preferred_chip_names, list), f"{path}.ranking.preferredChipNames must be an array")
        if isinstance(preferred_chip_names, list):
            for chip_index, chip_name in enumerate(preferred_chip_names):
                validator.require(
                    is_non_empty_string(chip_name),
                    f"{path}.ranking.preferredChipNames[{chip_index}] must be a non-empty string",
                )
        if ranking.get("hardwareFallback") is not None:
            validator.require(
                isinstance(ranking.get("hardwareFallback"), bool),
                f"{path}.ranking.hardwareFallback must be a boolean",
            )

    parameter_keys: set[str] = set()
    parameters = model.get("parameters")
    validator.require(isinstance(parameters, list), f"{path}.parameters must be an array")
    if isinstance(parameters, list):
        for param_index, parameter in enumerate(parameters):
            validator.require(isinstance(parameter, dict), f"{path}.parameters[{param_index}] must be an object")
            if isinstance(parameter, dict):
                key = validate_parameter(parameter, f"{path}.parameters[{param_index}]", validator)
                if key:
                    validator.require(key not in parameter_keys, f"{path}.parameters contains duplicate key: {key}")
                    parameter_keys.add(key)

    if isinstance(runtime_options, dict):
        chat_template = runtime_options.get("chatTemplate")
        if isinstance(chat_template, dict):
            parameter_kwargs = chat_template.get("parameterKwargs", {})
            if isinstance(parameter_kwargs, dict):
                for kwarg, parameter_key in parameter_kwargs.items():
                    validator.require(
                        parameter_key in parameter_keys,
                        f"{path}.runtimeOptions.chatTemplate.parameterKwargs.{kwarg} references unknown parameter: {parameter_key}",
                    )

    preset_ids: set[str] = set()
    presets = model.get("presets")
    validator.require(isinstance(presets, list), f"{path}.presets must be an array")
    if isinstance(presets, list):
        for preset_index, preset in enumerate(presets):
            preset_path = f"{path}.presets[{preset_index}]"
            validator.require(isinstance(preset, dict), f"{preset_path} must be an object")
            if not isinstance(preset, dict):
                continue
            preset_id = preset.get("id")
            validator.require(is_non_empty_string(preset_id), f"{preset_path}.id must be a non-empty string")
            if isinstance(preset_id, str):
                validator.require(preset_id not in preset_ids, f"{path}.presets contains duplicate id: {preset_id}")
                preset_ids.add(preset_id)
            validator.require(is_non_empty_string(preset.get("label")), f"{preset_path}.label must be a non-empty string")
            values = preset.get("values")
            validator.require(isinstance(values, dict), f"{preset_path}.values must be an object")
            if isinstance(values, dict):
                for value_key, value in values.items():
                    validator.require(value_key in parameter_keys, f"{preset_path}.values references unknown parameter: {value_key}")
                    validator.require(isinstance(value, str), f"{preset_path}.values.{value_key} must be a string")

    return {
        "id": model.get("id"),
        "backend": backend,
        "capabilities": set(capabilities if isinstance(capabilities, list) else []),
        "runtimeApi": runtime_api,
        "minRuntimeVersion": min_runtime,
        "runtimeComponent": runtime_component,
        "availability": availability,
        "runtimeOptions": runtime_options if isinstance(runtime_options, dict) else None,
    }


def validate_catalog(catalog: Any, validator: Validator) -> list[dict[str, Any]]:
    validator.require(isinstance(catalog, dict), "catalog root must be an object")
    if not isinstance(catalog, dict):
        return []

    require_int(catalog.get("schemaVersion"), "catalog.schemaVersion", validator, minimum=1)
    validator.require(catalog.get("schemaVersion") == 1, "catalog.schemaVersion must be 1")
    validate_version(catalog.get("catalogVersion"), "catalog.catalogVersion", validator)
    if catalog.get("minAppVersion") is not None:
        validate_version(catalog.get("minAppVersion"), "catalog.minAppVersion", validator)

    models = catalog.get("models")
    validator.require(isinstance(models, list) and len(models) > 0, "catalog.models must be a non-empty array")
    if not isinstance(models, list):
        return []

    seen_ids: set[str] = set()
    model_requirements: list[dict[str, Any]] = []
    for index, model in enumerate(models):
        validator.require(isinstance(model, dict), f"models[{index}] must be an object")
        if not isinstance(model, dict):
            continue
        model_id = model.get("id")
        if isinstance(model_id, str):
            validator.require(model_id not in seen_ids, f"catalog contains duplicate model id: {model_id}")
            seen_ids.add(model_id)
        model_requirements.append(validate_model(model, index, validator))
    return model_requirements


def validate_channel(
    channel: Any,
    catalog: Any,
    catalog_path: pathlib.Path,
    validator: Validator,
    allow_runtime_placeholders: bool,
) -> None:
    validator.require(isinstance(channel, dict), "channel root must be an object")
    if not isinstance(channel, dict):
        return

    require_int(channel.get("schemaVersion"), "channel.schemaVersion", validator, minimum=1)
    validator.require(channel.get("schemaVersion") == 1, "channel.schemaVersion must be 1")
    validator.require(channel.get("channel") == "stable", "channel.channel must be stable")

    catalog_asset = channel.get("catalog")
    validator.require(isinstance(catalog_asset, dict), "channel.catalog must be an object")
    if isinstance(catalog_asset, dict):
        validate_version(catalog_asset.get("version"), "channel.catalog.version", validator)
        validate_url(catalog_asset.get("url"), "channel.catalog.url", validator)
        validator.require(SHA256_RE.match(str(catalog_asset.get("sha256", ""))) is not None, "channel.catalog.sha256 must be SHA-256 hex")
        require_int(catalog_asset.get("sizeBytes"), "channel.catalog.sizeBytes", validator, minimum=1)

        if isinstance(catalog, dict):
            validator.require(
                catalog_asset.get("version") == catalog.get("catalogVersion"),
                "channel.catalog.version must match catalog.catalogVersion",
            )
        if catalog_path.exists():
            actual_sha = sha256_hex(catalog_path)
            actual_size = catalog_path.stat().st_size
            validator.require(catalog_asset.get("sha256") == actual_sha, "channel.catalog.sha256 does not match local catalog")
            validator.require(catalog_asset.get("sizeBytes") == actual_size, "channel.catalog.sizeBytes does not match local catalog")

    runtimes = channel.get("runtimes")
    validator.require(isinstance(runtimes, list), "channel.runtimes must be an array")
    if isinstance(runtimes, list):
        for index, runtime in enumerate(runtimes):
            runtime_path = f"channel.runtimes[{index}]"
            validator.require(isinstance(runtime, dict), f"{runtime_path} must be an object")
            if not isinstance(runtime, dict):
                continue
            validate_version(runtime.get("version"), f"{runtime_path}.version", validator)
            validator.require(runtime.get("platform") == "macos", f"{runtime_path}.platform must be macos")
            validator.require(runtime.get("arch") == "arm64", f"{runtime_path}.arch must be arm64")
            validate_url(runtime.get("url"), f"{runtime_path}.url", validator)
            if isinstance(runtime.get("url"), str):
                validator.require(runtime["url"].endswith(".zip"), f"{runtime_path}.url must point to a zip archive")
            sha = runtime.get("sha256")
            if sha == "replace-with-runtime-archive-sha256" and allow_runtime_placeholders:
                validator.warning(f"{runtime_path}.sha256 is still a placeholder")
            else:
                validator.require(SHA256_RE.match(str(sha or "")) is not None, f"{runtime_path}.sha256 must be SHA-256 hex")
            size_bytes = runtime.get("sizeBytes")
            if size_bytes is None and allow_runtime_placeholders:
                validator.warning(f"{runtime_path}.sizeBytes is still null")
            else:
                require_int(size_bytes, f"{runtime_path}.sizeBytes", validator, minimum=1)
            require_int(runtime.get("compatibilityApi"), f"{runtime_path}.compatibilityApi", validator, minimum=1)
            component = runtime.get("component", "base")
            validator.require(
                component in KNOWN_RUNTIME_COMPONENTS,
                f"{runtime_path}.component is unsupported: {component}",
            )
            min_app_version = runtime.get("minAppVersion")
            validator.require(isinstance(min_app_version, str) and bool(min_app_version.strip()), f"{runtime_path}.minAppVersion is required")
            if isinstance(min_app_version, str):
                validate_version(min_app_version, f"{runtime_path}.minAppVersion", validator)


def validate_runtime_manifest(
    manifest: Any,
    model_requirements: list[dict[str, Any]],
    validator: Validator,
) -> None:
    if manifest is None:
        return
    validator.require(isinstance(manifest, dict), "runtime manifest root must be an object")
    if not isinstance(manifest, dict):
        return

    validate_version(manifest.get("runtimeVersion"), "runtime.runtimeVersion", validator)
    require_int(manifest.get("compatibilityApi"), "runtime.compatibilityApi", validator, minimum=1)
    validator.require(manifest.get("platform") == "macos", "runtime.platform must be macos")
    validator.require(manifest.get("arch") == "arm64", "runtime.arch must be arm64")
    manifest_component = manifest.get("component", "base")
    validator.require(
        manifest_component in KNOWN_RUNTIME_COMPONENTS,
        "runtime.component is unsupported",
    )

    backends = set(manifest.get("supportedBackends", []))
    capabilities = set(manifest.get("capabilities", []))
    validator.require(backends.issubset(KNOWN_BACKENDS), "runtime.supportedBackends contains unsupported values")

    image_runtimes = manifest.get("imageRuntimes", {})
    validator.require(isinstance(image_runtimes, dict), "runtime.imageRuntimes must be an object")
    mflux_capabilities = {}
    if isinstance(image_runtimes, dict):
        mflux_capabilities = image_runtimes.get("mflux", {})
        validator.require(isinstance(mflux_capabilities, dict), "runtime.imageRuntimes.mflux must be an object")
        if isinstance(mflux_capabilities, dict):
            configs = mflux_capabilities.get("configs", [])
            classes = mflux_capabilities.get("classes", [])
            quantize_bits = mflux_capabilities.get("quantizeBits", [])
            validator.require(isinstance(configs, list), "runtime.imageRuntimes.mflux.configs must be an array")
            validator.require(isinstance(classes, list), "runtime.imageRuntimes.mflux.classes must be an array")
            validator.require(isinstance(quantize_bits, list), "runtime.imageRuntimes.mflux.quantizeBits must be an array")
            if isinstance(configs, list):
                validator.require(all(is_non_empty_string(value) for value in configs), "runtime.imageRuntimes.mflux.configs contains invalid values")
            if isinstance(classes, list):
                validator.require(all(is_non_empty_string(value) for value in classes), "runtime.imageRuntimes.mflux.classes contains invalid values")
            if isinstance(quantize_bits, list):
                validator.require(
                    all(isinstance(value, int) and not isinstance(value, bool) and value > 0 for value in quantize_bits),
                    "runtime.imageRuntimes.mflux.quantizeBits contains invalid values",
                )

    audio_runtimes = manifest.get("audioRuntimes", {})
    validator.require(isinstance(audio_runtimes, dict), "runtime.audioRuntimes must be an object")
    audio_adapters: set[str] = set()
    if isinstance(audio_runtimes, dict):
        adapters = audio_runtimes.get("adapters", [])
        validator.require(isinstance(adapters, list), "runtime.audioRuntimes.adapters must be an array")
        if isinstance(adapters, list):
            validator.require(all(is_non_empty_string(value) for value in adapters), "runtime.audioRuntimes.adapters contains invalid values")
            audio_adapters = set(adapters)

    manifest_version = manifest.get("runtimeVersion")
    for requirement in model_requirements:
        if requirement.get("availability") == "hidden":
            continue
        if requirement.get("runtimeApi") != manifest.get("compatibilityApi"):
            continue
        if requirement.get("runtimeComponent", "base") != manifest_component:
            continue
        minimum_runtime = requirement.get("minRuntimeVersion")
        if isinstance(manifest_version, str) and isinstance(minimum_runtime, str):
            if compare_versions(manifest_version, minimum_runtime) < 0:
                continue
        backend = requirement.get("backend")
        if backend:
            validator.require(backend in backends, f"runtime does not declare backend for catalog model {requirement.get('id')}: {backend}")
        missing_capabilities = requirement.get("capabilities", set()) - capabilities
        validator.require(
            not missing_capabilities,
            f"runtime is missing capabilities for catalog model {requirement.get('id')}: {sorted(missing_capabilities)}",
        )
        runtime_options = requirement.get("runtimeOptions")
        if isinstance(runtime_options, dict) and isinstance(mflux_capabilities, dict):
            mflux_options = runtime_options.get("mflux")
            if isinstance(mflux_options, dict):
                supported_configs = set(mflux_capabilities.get("configs", []))
                supported_classes = set(mflux_capabilities.get("classes", []))
                supported_quantize = set(mflux_capabilities.get("quantizeBits", []))
                config = mflux_options.get("config")
                text_class = mflux_options.get("textToImageClass")
                edit_class = mflux_options.get("editClass")
                quantize = mflux_options.get("quantize")
                validator.require(
                    config in supported_configs,
                    f"runtime is missing mflux config for catalog model {requirement.get('id')}: {config}",
                )
                if text_class is not None:
                    validator.require(
                        text_class in supported_classes,
                        f"runtime is missing mflux text class for catalog model {requirement.get('id')}: {text_class}",
                    )
                if edit_class is not None:
                    validator.require(
                        edit_class in supported_classes,
                        f"runtime is missing mflux edit class for catalog model {requirement.get('id')}: {edit_class}",
                    )
                if quantize is not None:
                    validator.require(
                        quantize in supported_quantize,
                        f"runtime is missing mflux quantize support for catalog model {requirement.get('id')}: {quantize}",
                    )
            audio_options = runtime_options.get("audio")
            if isinstance(audio_options, dict):
                adapter = audio_options.get("adapter")
                validator.require(
                    adapter in audio_adapters,
                    f"runtime is missing audio adapter for catalog model {requirement.get('id')}: {adapter}",
                )


def validate_runtime_channel_drift(
    channel: Any,
    manifest: Any,
    validator: Validator,
    allow_runtime_version_drift: bool,
) -> None:
    if not isinstance(channel, dict) or not isinstance(manifest, dict):
        return

    manifest_version = manifest.get("runtimeVersion")
    manifest_api = manifest.get("compatibilityApi")
    manifest_platform = manifest.get("platform")
    manifest_arch = manifest.get("arch")
    manifest_component = manifest.get("component", "base")
    runtimes = channel.get("runtimes")
    if not isinstance(runtimes, list):
        return

    for index, runtime in enumerate(runtimes):
        if not isinstance(runtime, dict):
            continue
        if runtime.get("platform") != manifest_platform or runtime.get("arch") != manifest_arch:
            continue
        if runtime.get("component", "base") != manifest_component:
            continue

        runtime_path = f"channel.runtimes[{index}]"
        version_matches = runtime.get("version") == manifest_version
        api_matches = runtime.get("compatibilityApi") == manifest_api
        if version_matches and api_matches:
            continue

        message = (
            f"{runtime_path} version/API ({runtime.get('version')}, {runtime.get('compatibilityApi')}) "
            f"does not match bundled runtime manifest ({manifest_version}, {manifest_api})"
        )
        if allow_runtime_version_drift:
            validator.warning(message)
        else:
            validator.error(message)


def parse_args() -> argparse.Namespace:
    script_dir = pathlib.Path(__file__).resolve().parent
    project_dir = script_dir.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=pathlib.Path, default=project_dir / "MLXtra/Resources/model-catalog.json")
    parser.add_argument("--channel", type=pathlib.Path, default=project_dir / "MLXtra/Resources/stable-channel.json")
    parser.add_argument(
        "--runtime-manifest",
        type=pathlib.Path,
        default=project_dir / "MLXtra/Resources/runtime/macos-arm64/runtime-manifest.json",
    )
    parser.add_argument(
        "--allow-runtime-placeholders",
        action="store_true",
        help="Permit placeholder runtime SHA/size values while preparing a release locally.",
    )
    parser.add_argument(
        "--allow-runtime-version-drift",
        action="store_true",
        help="Permit the bundled runtime manifest to differ from the stable channel runtime entry.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    validator = Validator()

    catalog = load_json(args.catalog, validator)
    channel = load_json(args.channel, validator)
    manifest = load_json(args.runtime_manifest, validator) if args.runtime_manifest else None

    model_requirements = validate_catalog(catalog, validator) if catalog is not None else []
    if channel is not None:
        validate_channel(channel, catalog, args.catalog, validator, args.allow_runtime_placeholders)
    if manifest is not None:
        validate_runtime_manifest(manifest, model_requirements, validator)
    if channel is not None and manifest is not None:
        validate_runtime_channel_drift(channel, manifest, validator, args.allow_runtime_version_drift)

    for warning in validator.warnings:
        print(f"warning: {warning}", file=sys.stderr)

    if validator.errors:
        for error in validator.errors:
            print(f"error: {error}", file=sys.stderr)
        return 1

    print("Release metadata validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
