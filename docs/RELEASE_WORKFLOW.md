# Catalog and Runtime Release Workflow

MLXtra has two update lanes:

- **Catalog-only update**: add or rerank curated models that the current runtime already supports.
- **Runtime update**: ship executable Python/runtime code. This must be immutable, checksum-verified, and automatically installed by the app when no compatible runtime is present.
- **App update**: ship a signed and notarized MLXtra app bundle through Sparkle using a GitHub-hosted appcast.

The app must always open with the bundled catalog if remote metadata is unavailable or invalid. Runtime-dependent generation waits until a compatible runtime has been downloaded and installed.

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
- `runtimes` should point at the current runtime archive for public builds; when no compatible installed runtime exists, the app starts the download automatically.
- Published at the moving GitHub release tag `stable` as
  `https://github.com/mlxtra/mlxtra/releases/download/stable/stable-channel.json`.

Runtime archive

- Filename: `runtime-macos-arm64-<version>.zip`.
- Root can be the runtime directory itself or a single containing directory; the app normalizes both during install.
- Must contain `runtime-manifest.json`, `venv/bin/python`, `acestep-venv/bin/python`, bundled Python, and download helpers.

## Validate Metadata

Run this before preparing or publishing release assets:

```bash
Scripts/validate-release-metadata.py
```

While a generated channel candidate still contains a local runtime archive placeholder, use:

```bash
Scripts/validate-release-metadata.py --allow-runtime-placeholders
```

The validator checks catalog schema, required model fields, source metadata, parameter/preset consistency, channel checksums, channel sizes, and whether the local runtime manifest declares the backends and capabilities required by the catalog.

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

## Publish GitHub Release Assets

Use the publishing wrapper after local validation has passed:

```bash
Scripts/publish-release-assets.sh --repo mlxtra/mlxtra
```

The repository must be public before running the normal publish command.
MLXtra fetches release metadata and runtime archives with unauthenticated
`URLSession` requests, so private GitHub release asset URLs return 404 in the
app. For internal publishing tests against a private repository, pass
`--allow-private`; do not use that for app-visible releases.

This runs `Scripts/prepare-release-assets.sh`, then publishes:

- `model-catalog.json` to immutable release tag `catalog-<version>`
- `runtime-macos-arm64-<version>.zip` plus legal files to immutable release tag `runtime-<version>`
- `stable-channel.json` to moving release tag `stable`

For a catalog-only channel update, or when reusing an already-published runtime
entry from the checked-in channel file:

```bash
Scripts/publish-release-assets.sh --repo mlxtra/mlxtra --skip-runtime-archive
```

By default, existing assets on `catalog-*` and `runtime-*` releases cause the
script to fail, because those releases are treated as immutable. Use
`--force-immutable` only to repair a mistaken unpublished/internal release.
The `stable` release asset is intentionally replaced each time, but the `stable`
release is not marked as GitHub's Latest release; the latest public release
should remain the current `app-*` DMG release.

To preview the GitHub write operations without uploading assets:

```bash
Scripts/publish-release-assets.sh --repo mlxtra/mlxtra --dry-run
```

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

5. Publish the generated release assets:

```bash
Scripts/publish-release-assets.sh --repo mlxtra/mlxtra --skip-runtime-archive
```

## Runtime Update

1. Build the runtime bundle:

```bash
Scripts/build-runtime-bundle.sh
```

2. Validate it:

```bash
Scripts/validate-runtime-bundle.sh
```

3. Stage and publish the release assets:

```bash
Scripts/publish-release-assets.sh --repo mlxtra/mlxtra --write-channel
```

4. Commit the checked-in channel update after the publish succeeds:

```bash
git status --short
git add MLXtra/Resources/stable-channel.json
git commit -m "Update stable runtime channel"
git push
```

This keeps the bundled fallback channel aligned with the public `stable`
release asset. Do not commit a channel file that points at assets that were not
successfully uploaded.

5. Run one smoke test per backend before announcing the release:

```bash
swift test
cd Tests/PythonTests
PYTHONPATH=../../../MLXtra/Resources python3 test_python_bridge.py -v
PYTHONPATH=../../../MLXtra/Resources python3 test_acestep_bridge.py -v
cd ../..
xcodebuild -project MLXtra.xcodeproj -scheme MLXtra -configuration Debug build
MLXTRA_REQUIRE_ALL_MODELS=1 python3 Tests/IntegrationTests/test_music_integration.py
MLXTRA_REQUIRE_ALL_MODELS=1 python3 Tests/IntegrationTests/test_all_models_integration.py
```

The `MLXTRA_REQUIRE_ALL_MODELS=1` runs are the release gate. Without that
setting, the integration scripts keep local development convenient by reporting
missing model files as skips.

GitHub Actions also includes a manual `Runtime Validation` workflow. Run it
before publishing a binary/runtime release; it builds the runtime bundle, runs
`Scripts/validate-runtime-bundle.sh`, and builds the app.

## Binary App Release

MLXtra uses Sparkle 2 for self-updating app binaries. The appcast URL is baked
into the app as:

```text
https://github.com/mlxtra/mlxtra/releases/download/appcast-stable/appcast.xml
```

Sparkle's public EdDSA key is supplied through the
`MLXTRA_SPARKLE_PUBLIC_ED_KEY` Xcode build setting. The Release configuration
embeds the public key; keep the private key outside the repository in the macOS
Keychain account used by Sparkle.

The Xcode Release configuration enables the hardened runtime. For a public
binary app, archive with a Developer ID Application identity and notarize the
exported `.app` or `.dmg`; the checked-in project uses ad-hoc signing for local
source builds unless those signing values are supplied at archive time.

### One-Time App Release Setup

Install or resolve Sparkle's command-line tools:

```bash
swift package resolve
```

Generate the Sparkle EdDSA key pair on the release machine:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account mlxtra
```

The private key is stored in the macOS login Keychain. The command prints the
public key; put that value in the Release configuration's
`MLXTRA_SPARKLE_PUBLIC_ED_KEY` build setting, or pass it to
`Scripts/publish-app-release.sh` with `--public-key`. Never export or commit the
private key.

For notarization, create an Apple app-specific password for the Apple ID in the
Apple Account security settings. The first `--setup-notary` run stores it in the
local Keychain as the `mlxtra-notary` notarytool profile.

Release tags:

- `app-<version>`: immutable release containing notarized `MLXtra-<version>.dmg`
- `appcast-stable`: moving release containing the current `appcast.xml` and
  release notes referenced by the appcast

Check the printed DMG size before upload. GitHub release assets must stay under
2 GiB per file. The app DMG should remain small because the Python/MLX runtime is
published as a separate runtime asset.

App release flow:

1. Increment `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, then commit and
   push that source change before publishing:

```bash
git status --short
git add MLXtra.xcodeproj/project.pbxproj
git commit -m "Bump app version to <version>"
git push
```

2. For the first app release on a machine, let the release script store App
   Store Connect notarization credentials:

```bash
Scripts/publish-app-release.sh --repo mlxtra/mlxtra --setup-notary --apple-id "<apple-id>"
```

The script auto-detects a single installed Developer ID Application identity,
infers the Apple Developer Team ID from it, stores credentials in the
`mlxtra-notary` keychain profile, then continues with the release. If multiple
Developer ID Application identities are installed, pass the intended one with
`--signing-identity`.

If you already created a notary profile with a different name, pass it with
`--notary-keychain-profile "<profile-name>"`.

3. For later releases from the same machine, run:

```bash
Scripts/publish-app-release.sh --repo mlxtra/mlxtra
```

4. To run a local packaging dry run:

```bash
Scripts/publish-app-release.sh --skip-notarization --skip-publish
```

This dry run proves archive, packaging, Sparkle signing, and appcast generation,
but it is not a public distribution artifact. When notarization is skipped,
Gatekeeper reports the DMG as unnotarized. If you want the dry run to use the
Developer ID certificate while still skipping Apple notarization, pass
`--signing-identity` and `--team-id` explicitly.

The repository must be public before publishing app-visible assets. For an
internal private-repository test, pass `--allow-private`; do not use that for
public app updates because the app downloads updates with unauthenticated HTTPS.

The release script archives the Release build, embeds the Sparkle public key,
removes the local development runtime from `Contents/Resources/runtime`, signs
nested code if present, re-signs and verifies the app, creates and signs the DMG
container, notarizes and staples both the app and DMG, validates the final DMG
with Gatekeeper, generates `appcast.xml` from the final DMG bytes, uploads the
DMG to `app-<version>`, and replaces `appcast.xml` plus its release notes on
`appcast-stable`.

5. Install the previous public version and use `Check for Updates...` to verify
   Sparkle can discover and install the new release.

Minimum signing validation before upload:

```bash
codesign -dvvv --entitlements :- .build/app-release/app/MLXtra.app
codesign -dvvv .build/app-release/assets/MLXtra-<version>.dmg
xcrun stapler validate .build/app-release/assets/MLXtra-<version>.dmg
spctl -a -vv -t open --context context:primary-signature .build/app-release/assets/MLXtra-<version>.dmg
```

## Rollback

Do not mutate published catalog or runtime assets. To roll back, publish a new `stable-channel.json` that points back to the previous known-good catalog/runtime asset versions.

Remote failure, bad checksums, incompatible schema, and invalid runtime bundles should leave the current installed runtime untouched. If no runtime is installed yet, the app remains usable but runtime-dependent generation is unavailable until a valid runtime download succeeds.
