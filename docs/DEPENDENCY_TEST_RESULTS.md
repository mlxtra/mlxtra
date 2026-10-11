# Dependency upgrade test results — 2026-10-11

Testing used the rebuilt runtime 0.1.10 and the Xcode Debug app on this Apple
Silicon Mac (128 GB memory). The initial blocker was missing catalog model
weights, rather than missing credentials or hardware. Hugging Face access,
including Ideogram, worked with the existing credentials.

## Results

| Check | Result |
| --- | --- |
| Catalog profile smoke checks | 16 of 17 passed; Gemma 12B chat works, red-image quality assertion fails |
| Swift tests and coverage | 674 passed; core line coverage 85.96% (80% required) |
| Python compilation and unit tests | 121 passed, including coverage bundle discovery regression checks |
| App build with runtime validation | Passed; signing disabled |
| Rebuilt base and music runtimes | Exact dependency pins, imports, and `pip check` passed |
| Both release archives | Extraction, imports, and Metal computation passed |
| Release channel | Strict metadata validation passed; archive hashes and sizes match public runtime/catalog assets |
| Full shared CI | `Scripts/ci.sh` passed, including metadata, both archives, Python, Swift coverage, and app build |
| Hosted runtime validation | Clean runtime build, validation, and app build passed |
| Qwen3.5 2B chat | Answered `4` through the bridge and native app |
| Qwen3.5 2B vision | Correctly identified a red square |
| FLUX.2 klein 4B | Generated a valid 512×512 red-circle PNG offline |
| Z-Image Turbo | Valid 512×512 red-circle PNG; nine steps and 8-bit runtime quantization |
| Ideogram 4 FP8 | Valid 1024×1024 red-circle PNG; catalog 20-step preset; about nine minutes |
| Kokoro 82M | Single-request and repeated speech passed offline, including embedded app Python |
| ACE-Step | All six dedicated checks passed, including instrumental, lyrics, and forwarding |
| Magenta RealTime 2 base | Real compiled-model load and two-second 48 kHz stereo WAV passed |
| Magenta RealTime 2 small | Real compiled-model load and 20-second 48 kHz stereo WAV passed |
| Higgs Audio v3 | Offline generation passed; 2.68-second, non-silent 24 kHz mono WAV |
| KugelAudio | Offline generation passed; 6.4-second, non-silent 24 kHz mono WAV |
| Sustained chat and cancellation | Long streamed reply followed by three successful requests; loading/streaming/music-child termination and fresh-process recovery passed |
| Native Stop/recovery | Stopped a long reply, composer recovered, next request returned `4` |
| Signed Sparkle installation | Developer ID packaging and EdDSA-signed loopback update 17→18 passed; installed signature verifies and actual MLXtra relaunched |
| Production HTTPS update feed | Actual `AppUpdateController` fetched the configured appcast and reported `upToDate` |
| Apple notarization and Gatekeeper | Signed DMG accepted by Apple, ticket stapled and validated; Gatekeeper accepted as Notarized Developer ID |
| Native speech playback | Speech output shown; Play/Pause worked and playback advanced |

Thirty WAV outputs were also checked for non-zero samples. The image and audio outputs
are preserved under `.build/model-validation/outputs/`. Logs and the local
cache-override test driver are under `.build/model-validation/`.

The first hosted release CI run passed all 674 Swift tests but failed while
discovering the coverage executable: native SwiftPM omitted `CFBundleExecutable`
from its test bundle. The coverage script now also discovers regular executable
files in bundles without that metadata, with regression checks for both a missing
plist and a plist without the key. The 80% coverage threshold remains enforced.

All 11 existing all-model checks and all five new resilience checks passed.
The existing checks ran across sequential batches with strict
missing-model checks. Large weights were downloaded into an isolated cache and
removed after testing to fit the available disk space. Qwen3.5 2B and Kokoro were
also made available in the normal Hugging Face cache for native app testing;
existing cached models were preserved.

<!-- catalog-vision-results -->
All eight vision profiles were exercised, including Qwen 2B above. Additional profiles:

- `mlx-community/Qwen3.5-9B-MLX-4bit`: chat returned `4`, image input identified red.
- `google/gemma-4-e4b-it`: chat returned `4`, image input identified red.
- `mlx-community/gemma-4-e2b-it-4bit`: chat returned `4`, image input identified red.
- `mlx-community/gemma-4-12B-it-4bit`: chat returned `4`, but the red image was incorrectly identified as black.
- `mlx-community/gemma-4-26b-a4b-it-4bit`: chat returned `4`, image input identified red.
- `mlx-community/Qwen3.6-27B-4bit`: chat returned `4`, image input identified red.
- `mlx-community/Qwen3.6-35B-A3B-4bit`: chat returned `4`, image input identified red.
<!-- /catalog-vision-results -->

## Issues found and corrected

1. Kokoro installed spaCy English data on its first request, writing pip output
   into the JSON stream. The runtime now bundles a checksum-pinned English data
   wheel, and audio loader diagnostics go to stderr.
2. eSpeak failed inside the longer embedded app path. The bundled native library
   uses a small path buffer; data now uses a short, process-lifetime temporary
   copy. A symlink would be resolved back to the long path by phonemizer.
3. Magenta's published compiled model failed with MLX 0.32.3. Its isolated
   environment retains MLX/Metal 0.31.2, which passed real generation.
4. Upstream MFLUX removed Ideogram's `use_preset_steps` argument. The bridge now
   selects preset steps with `num_inference_steps=None` and retains compatibility
   with the older explicit argument.

The stale model warning is also corrected: downloaded-model fallback clears
obsolete preflight status, and a delayed cache inspection cannot overwrite a
newer explicit selection. Two Swift regressions failed before this fix and pass
afterward; genuine generation download requirements remain intact. Unit regressions cover
speech diagnostics, long-path copying/reuse, and both
Ideogram API forms. `Tests/IntegrationTests/test_magenta_integration.py` adds a
real model-loading check that catches compiled-function format incompatibility.

## Vision failure reproduced on both runtimes

Gemma 4 12B (MLX 4-bit checkpoint revision
`73bcf09092aa277861d5a191b989b666f7f32e8f`) consistently answers `Black`
for solid red 128×128 and 512×512 RGB PNGs, while correctly answering `Blue`
for a blue fixture. Text chat returns `4` correctly. The same red failure
reproduces in the upstream MLX-VLM CLI, with the app bridge bypassed, and
in the previous runtime (MLX 0.31.2, MLX-VLM 0.6.1, Transformers 5.8.0).
The upgrade therefore did not introduce this observed failure.

The current MLX processor produces exactly the same pixel values, patch
positions, and token counts as the Transformers reference for both fixtures.
This narrows the investigation to the checkpoint or upstream inference code;
it does not establish the exact cause. This vision profile remains a failed
quality check and should be investigated before claiming full catalog support.
The smaller Gemma profiles and Gemma 26B passed the red-image check.

`Tests/IntegrationTests/test_catalog_vision.py` preserves chat plus red/blue
image assertions as an offline, repeatable test. Qwen 2B passes all three;
Gemma 12B fails the red assertion, without relaxing the expected answer.
Run a selected cached profile with:

```bash
HF_HUB_CACHE="$PWD/.build/model-validation/hub" \
MLXTRA_REQUIRE_ALL_MODELS=1 \
MLXTRA_INTEGRATION_VISION_MODELS=mlx-community/gemma-4-12B-it-4bit \
/usr/bin/python3 Tests/IntegrationTests/test_catalog_vision.py
```

Set `HF_HUB_CACHE` for a separate cache and
`MLXTRA_INTEGRATION_OUTPUT_DIR` for isolated fixtures/JSON evidence.
No models are downloaded by this test.

## Remaining coverage and release requirements

- The signed Sparkle installation test used isolated app identities and a
  loopback HTTP feed. The actual app update controller also fetched the production HTTPS appcast
  successfully. Apple accepted the local signed DMG, its ticket is stapled, and
  Gatekeeper accepted it as Notarized Developer ID. The final rebuilt app
  embeds the 0.1.10 channel and retains the previous public app's Sparkle key.
  The normal Debug app keeps its update check disabled.
- All 17 catalog profiles were smoke-tested: 16 passed; Gemma 12B failed image
  understanding as documented above. Large passing-model weights were removed
  from the isolated cache; Gemma 12B weights remain there for reproduction.
- Listening/quality review, lower memory machines, and macOS 14 remain outside
  this run. Extended chat/music and cancellation now have real-model checks.
- Real-model tool calling, optional MTP acceleration, image editing, and a full
  matrix of generation settings remain outside these catalog smoke checks.
- Xcode UI automation was attempted unsigned, ad hoc signed, and Developer ID
  signed. The runner exited with SIGKILL before connecting, so none of the 23
  automated UI tests ran. Native app checks used computer interaction instead;
  no security settings were changed.
- The earlier 0.1.10/0.1.9 metadata mismatch is resolved. The immutable
  runtime 0.1.10 and catalog 2026.06.10.1 assets are public; unauthenticated
  URLs and hashes/sizes were verified. The final app and moving feed pointers
  are published after release-source CI passes.

The full `Scripts/ci.sh` passed after updating the bundled channel, with
no metadata drift override. Hosted `Runtime Validation` also passed. Detailed
release notes are in `docs/releases/1.0.16.md`.
