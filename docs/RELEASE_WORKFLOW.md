# Catalog and Runtime Release Workflow

MLXtra has two update lanes:

- **Catalog-only update**: add or rerank curated models that the current runtime already supports.
- **Runtime update**: ship executable Python/runtime code. This must be immutable, checksum-verified, and explicitly installed by the user.

The app must always keep working with the bundled catalog and bundled runtime if remote metadata is unavailable or invalid.

## Release Files

`MLXtra/Resources/model-catalog.json`

- Bundled fallback catalog.
- Uses schema version `1`.
- Contains curated model profiles, source metadata, runtime requirements, parameters, presets, and ranking.
- Remote catalog assets should be uploaded unchanged to an immutable GitHub Release.

`MLXtra/Resources/stable-channel.json`

- Stable pointer to the current catalog and any published runtime update assets.
- Contains version, URL, size, and SHA-256 for each asset.
- This file is the only metadata that should move forward between immutable asset releases.
- `runtimes` can be empty when no remote runtime update has been published yet; the app keeps using the bundled runtime.

Runtime archive

- Filename: `runtime-macos-arm64-<version>.zip`.
- Root can be the runtime directory itself or a single containing directory; the app normalizes both during install.
- Must contain `runtime-manifest.json`, `venv/bin/python`, bundled Python, and download helpers.

## Validate Metadata

Run this before preparing or publishing release assets:

```bash
Scripts/validate-release-metadata.py
```

While a generated channel candidate still contains a local runtime archive placeholder, use:

```bash
Scripts/validate-release-metadata.py --allow-runtime-placeholders
```

The validator checks catalog schema, required model fields, source metadata, parameter/preset consistency, channel checksums, channel sizes, and whether the bundled runtime manifest declares the backends and capabilities required by the catalog.

## Prepare Local Release Assets

Generate a release staging directory:

```bash
Scripts/prepare-release-assets.sh --repo mlxtra/mlxtra
```

This creates:

- `.build/release/model-catalog.json`
- `.build/release/runtime-macos-arm64-<version>.zip`
- `.build/release/stable-channel.json`
- `.build/release/LICENSE`
- `.build/release/NOTICE`
- `.build/release/THIRD_PARTY_NOTICES.md`

The script computes SHA-256 and size values, writes a channel candidate, and validates the generated metadata.

To update the bundled channel file after generating a real runtime archive:

```bash
Scripts/prepare-release-assets.sh --repo mlxtra/mlxtra --write-channel
```

If you only want to stage the catalog/channel shape without zipping the 3GB runtime:

```bash
Scripts/prepare-release-assets.sh --skip-runtime-archive
```

When the checked-in stable channel has no published runtime entry, this writes a
catalog-only channel candidate with an empty `runtimes` array. When it does have
one, the script reuses that whole runtime entry unchanged; do not combine this
mode with `--runtime-version`.

## Catalog-Only Update

1. Edit `MLXtra/Resources/model-catalog.json`.
2. Keep the model set curated. Do not add a generic Hugging Face browser or arbitrary local paths in v1.
3. Ensure each new model has:
   - source metadata
   - runtime compatibility
   - memory and download size estimates
   - ranking values
   - parameters and presets
4. Run:

```bash
Scripts/validate-release-metadata.py --allow-runtime-placeholders
swift test --filter ModelCapabilityProfileTests
```

5. Upload `model-catalog.json` to an immutable GitHub Release tag such as `catalog-2026.05.09`.
6. Update `stable-channel.json` to point to the new catalog URL, size, and SHA-256.
7. Publish the new `stable-channel.json`.

## Runtime Update

1. Build the runtime bundle:

```bash
Scripts/build-runtime-bundle.sh
```

2. Validate it:

```bash
Scripts/validate-runtime-bundle.sh
```

3. Stage the release assets and update local channel metadata:

```bash
Scripts/prepare-release-assets.sh --repo mlxtra/mlxtra --write-channel
```

4. Upload `.build/release/runtime-macos-arm64-<version>.zip` to an immutable GitHub Release tag such as `runtime-0.1.0`.
5. Upload `.build/release/LICENSE`, `.build/release/NOTICE`, and `.build/release/THIRD_PARTY_NOTICES.md` with binary app/runtime release assets.
6. Upload `.build/release/model-catalog.json` to the catalog release tag if the catalog changed.
7. Publish `.build/release/stable-channel.json` as the stable channel pointer.
8. Run one smoke test per backend before announcing the release:

```bash
swift test
cd Tests/PythonTests
PYTHONPATH=../../../MLXtra/Resources python3 test_python_bridge.py -v
PYTHONPATH=../../../MLXtra/Resources python3 test_acestep_bridge.py -v
cd ../..
xcodebuild -project MLXtra.xcodeproj -scheme MLXtra -configuration Debug build
MLXTRA_REQUIRE_ALL_MODELS=1 python3 test_music_integration.py
MLXTRA_REQUIRE_ALL_MODELS=1 python3 test_all_models_integration.py
```

The `MLXTRA_REQUIRE_ALL_MODELS=1` runs are the release gate. Without that
setting, the integration scripts keep local development convenient by reporting
missing model files as skips.

GitHub Actions also includes a manual `Runtime Validation` workflow. Run it
before publishing a binary/runtime release; it builds the runtime bundle, runs
`Scripts/validate-runtime-bundle.sh`, and builds the app without
`MLXTRA_SKIP_RUNTIME_VALIDATION`.

## Binary App Release

The Xcode Release configuration enables the hardened runtime. For a public
binary app, archive with a Developer ID Application identity and notarize the
exported `.app` or `.dmg`; the checked-in project uses ad-hoc signing for local
source builds unless those signing values are supplied at archive time.

Minimum signing validation before upload:

```bash
codesign -dvvv --entitlements :- path/to/MLXtra.app
spctl -a -vv path/to/MLXtra.app
```

## Rollback

Do not mutate published catalog or runtime assets. To roll back, publish a new `stable-channel.json` that points back to the previous known-good catalog/runtime asset versions.

Remote failure, bad checksums, incompatible schema, and invalid runtime bundles should all leave users on the bundled fallback path.
