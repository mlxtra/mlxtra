# Runtime 0.1.10 dependency upgrade

Prepared and checked locally on 2026-10-11 with Xcode 27.0, Swift 6.4, and
Apple Silicon. The bundled fallback channel now references runtime 0.1.10.
The immutable runtime and catalog assets have been published and verified
through unauthenticated download URLs.

## Selected versions

| Dependency | Previous | Candidate |
| --- | --- | --- |
| Swift Markdown / cmark | 0.7.3 / 0.7.1 | 0.9.0 |
| Sparkle | 2.9.1 | 2.10.0 |
| Python | 3.12.8 | 3.12.15 |
| OpenSSL | 3.0.15 | 3.5.9 |
| liblzma | Installer-provided | XZ 5.8.4, static |
| MLX / MLX Metal | 0.31.2 | 0.32.3 |
| MLX-VLM | 0.6.1 | 0.7.6 |
| MLX-Audio | 0.4.4 | 0.5.8 |
| MFLUX | Fork, 0.17.5 | Upstream PyPI 0.22.0 |
| Transformers | 5.8.0 | 5.19.0 |
| Hugging Face Hub | 1.14.0 | 1.33.0 |
| Pillow | 12.2.0 | 12.3.0 |
| Torch / Torchvision, main environment | 2.11.0 / 0.26.0 | 2.14.1 / 0.29.1 |
| ACE-Step | `6c1b2ef…` | v0.1.8, `dce6214…` |
| Magenta RealTime | 2.0.2 | 2.0.3 |
| MLX / MLX Metal, Magenta environment | 0.31.2 | 0.31.2 (compiled-model compatibility) |
| Kokoro English language data | Downloaded on first use | Bundled `en_core_web_sm` 3.8.0 |

Misaki stays at 0.9.4, which requires Python below 3.13. Hub remains on 1.x
because MFLUX requires Hub below 2. NumPy stays at 2.4.4 in the main environment.
The music environments remain isolated and resolve their own compatible
Transformers, Torch, and NumPy versions. All three environments pass `pip check`.

Primary sources: [Swift Markdown](https://github.com/swiftlang/swift-markdown/releases/tag/0.9.0),
[Sparkle](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0),
[Python](https://www.python.org/downloads/release/python-31215/),
[OpenSSL](https://github.com/openssl/openssl/releases/tag/openssl-3.5.9),
[XZ](https://github.com/tukaani-project/xz/releases/tag/v5.8.4),
[MLX-VLM](https://pypi.org/project/mlx-vlm/0.7.6/),
[MLX-Audio](https://pypi.org/project/mlx-audio/0.5.8/),
[MFLUX](https://pypi.org/project/mflux/0.22.0/),
[ACE-Step](https://github.com/ace-step/ACE-Step-1.5/releases/tag/v0.1.8),
and [Magenta](https://pypi.org/project/magenta-rt/2.0.3/).

## Compatibility changes

- Swift Markdown requires Swift tools 6.2. Package.swift retains Swift 5
  language mode; the developer requirement is now Xcode 26 or later.
- Source-only Python security releases are built from SHA-256 verified Python,
  OpenSSL, and XZ sources. The arm64 framework targets macOS 14 and links
  OpenSSL/liblzma statically. TLS loads `/etc/ssl` trust roots. Framework and
  standard-library extensions have no developer-directory library dependencies.
- All main Python pins are resolved together. The MLX Metal wheels remain
  explicitly selected for macOS 14. Download helpers and license texts are
  included in fresh output directories.
- Magenta 2.0.3 uses `MagentaRT2StdMlxfn`, `cfg_scales`, and a conditioning
  dictionary. The bridge also retains support for the published 2.0.2 API.
  Real generation exposed incompatible `.mlxfn` serialization in MLX 0.32.3;
  Magenta therefore keeps MLX/Metal 0.31.2 in its isolated environment.
  [Upstream issue](https://github.com/magenta/magenta-realtime/issues/103).
- Kokoro requires spaCy English data. It is installed from a pinned, SHA-256
  checked upstream wheel during bundling, so the first request needs no pip
  subprocess or network access. Audio loader diagnostics go to stderr.
  eSpeak data is copied to a short temporary directory when an app bundle path
  exceeds the native library's path buffer; phonemizer resolves symlinks, so a
  symlink alone cannot fix this.
- Upstream Ideogram selects preset steps with `num_inference_steps=None`; the
  bridge translates the catalog's `use_preset_steps` flag to that form and
  retains the explicit flag for the older runtime API.
- Swift coverage discovers each XCTest bundle's declared executable, including
  the Xcode build system's `MLXtraTests.xctest` layout.

## Validation and remaining release gates

- Shared CI Python compilation and unit tests: 120 tests pass.
- Shared CI Swift coverage: 674 tests pass; core line coverage is 85.96%
  against the unchanged 80% requirement.
- Xcode app build passes with runtime validation enabled and signing disabled,
  using destination `platform=macOS,arch=arm64`. With Xcode 27,
  `-disableAutomaticPackageResolution -skipPackageUpdates` avoids a sporadic
  package-resolution wait after dependencies have already been resolved.
- Runtime structure, exact package versions, TLS trust roots, image class/config
  imports, audio imports, ACE-Step imports, and Magenta imports pass.
- Both distributable archives pass extraction, structural/import validation,
  and Metal smoke checks, including the isolated ACE-Step and Magenta runtimes.
  Staged channel checksums and byte sizes match the archives.
- Metal computation and a real persistent bridge load/generate/unload request
  pass with a locally constructed tiny random Qwen3 model and cached tokenizer.
  This checks execution and the protocol; it does not check generation quality.
- Real Qwen3.5 2B chat answers `4`; an image request identifies a red square.
  Kokoro single-request and persistent speech sessions pass with downloads
  disabled. Magenta produces a valid, non-silent 20-second stereo WAV.
  All six dedicated ACE-Step tests pass, including instrumental, lyric, and
  main-bridge forwarding requests. FLUX produces a valid 512×512 PNG; Ideogram
  produces a valid 1024×1024 PNG with its catalog 20-step preset. All 11 existing
  integration checks pass across sequential batches, plus image-understanding
  and Magenta generation checks. See `DEPENDENCY_TEST_RESULTS.md` for coverage
  limits and the native model-status fix. Extended testing also covers all
  image/audio/music catalog profiles, sustained chat, and cancellation/restart.
  Gemma 12B fails a red-image quality assertion in both the old and new runtimes
  and the upstream CLI; the new offline catalog vision test preserves that
  failure. All 17 catalog profiles have now been exercised; 16 pass their smoke
  checks, with this pre-existing Gemma 12B vision failure recorded explicitly.
- Full `Scripts/ci.sh` passes, including strict metadata parity, both runtime
  archives, Python checks, Swift coverage, and the app build. The hosted
  `Runtime Validation` workflow also passed from the release source branch.

Local bundles are under `.build/runtime-upgrade/`; previous development bundles
are preserved under `.build/runtime-before-upgrade/`. Release assets and the
unpublished channel candidate are staged under `.build/dependency-upgrade-release/`.
The final Developer ID signed app and DMG are under `.build/publish-1.0.16/app/`;
Apple notarization, app/DMG stapling, and Gatekeeper validation passed. The final
app bundles the verified 0.1.10 channel. Its bundle ID, Sparkle public key, and
feed URL match the previous public app 1.0.15. The final DMG SHA-256 is
`2a5ae2046ff76f95ad9d2bf075e9fd2e3642e212b483e600b84ab1cb40336c64`.
The earlier `.build/dependency-app-test/` DMG was a test artifact with an obsolete
0.1.9 fallback channel and is superseded by this rebuilt artifact.

Publish the final app and activate the stable/Sparkle feeds after CI passes on
the release source. Release notes are in `docs/releases/1.0.16.md` and disclose
the Gemma 12B vision failure and remaining test coverage. Follow
`docs/RELEASE_WORKFLOW.md` for subsequent releases.
