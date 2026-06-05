# MLXtra

**Local AI creation for Mac, beyond chat.**

MLXtra is a native Apple Silicon app for local AI creation. It runs chat,
vision, image, speech, and music models on your Mac with
[MLX](https://github.com/ml-explore/mlx), without turning setup into a model
server project.

[Download MLXtra 1.0.14 DMG](https://github.com/mlxtra/mlxtra/releases/download/app-1.0.14/MLXtra-1.0.14.dmg)
| [Watch demo](https://raw.githubusercontent.com/mlxtra/mlxtra/main/docs/assets/demo/MLXtra.mp4)
| [View releases](https://github.com/mlxtra/mlxtra/releases)
| [Build from source](#build-from-source)

![MLXtra home screen](docs/assets/screenshots/home.png)

## What's Different

- **Creative modes, not just chat.** Move between conversation, image
  generation, text-to-speech, and music generation from the same composer.
- **Mac-first runtime.** MLXtra ships a verified Apple Silicon runtime and
  keeps model downloads inside the app instead of asking you to use terminal
  commands or manage model-server setup.
- **Curated local models.** The catalog favors models that are practical on
  Macs, including lightweight starters and larger options that appear only when
  the hardware fit makes sense.
- **Generated media is handled like app output.** Images, speech, and music are
  saved locally, shown in the conversation, and easy to open or export.
- **Simple first run.** Download the app, choose a model, and let MLXtra handle
  runtime and model setup in the background.

## Demo


<video src="https://github.com/user-attachments/assets/d76ef5c7-c76c-4a39-8a7b-838b4b9a6abd" controls width="100%" title="MLXtra demo"></video>

[Watch the demo video](https://raw.githubusercontent.com/mlxtra/mlxtra/main/docs/assets/demo/MLXtra.mp4)

## What You Can Do

- Chat with local vision-language models and attach images
- Generate images with FLUX.2 Klein, Ideogram 4, or Z-Image Turbo
- Generate speech with KugelAudio or Kokoro
- Generate music with ACE-Step or Magenta RealTime 2
- Manage runtime and model downloads from Settings
- Stream responses and keep conversation history locally

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon Mac
- Internet connection for the first runtime and model downloads
- Sufficient free disk space for selected models

Model sizes vary. Small chat models are a few GB; image and speech models can be
larger.

## Models

MLXtra ships with a curated model catalog. The current bundled catalog is
`2026.06.04.2` and requires MLXtra `1.0.12` or newer. Download sizes below are
main model downloads; acceleration entries list the extra draft-model download
size when one is included.

### Chat and Vision

| Model | Download | Est. memory | Runtime | Acceleration |
| --- | ---: | ---: | --- | --- |
| Qwen 3.5 2B | 1.75 GB | 3.0 GB | 0.1.0+ | - |
| Qwen 3.5 9B | 5.98 GB | 6.0 GB | 0.1.6+ | Qwen 3.5 9B MTP, +0.16 GB |
| Gemma 4 E2B | 3.61 GB | 4.0 GB | 0.1.6+ | Gemma 4 E2B assistant draft, +0.19 GB |
| Gemma 4 E4B | 16.02 GB | 3.0 GB | 0.1.6+ | Gemma 4 E4B assistant draft, +0.19 GB |
| Gemma 4 12B | 11.02 GB | 12.0 GB | 0.1.6+ | Gemma 4 12B assistant draft, +0.88 GB |
| Gemma 4 26B A4B | 15.64 GB | 17.5 GB | 0.1.6+ | Gemma 4 26B A4B assistant draft, +0.87 GB |
| Qwen 3.6 27B | 16.08 GB | 18.0 GB | 0.1.6+ | Qwen 3.6 27B MTP, +0.26 GB |
| Qwen 3.6 35B A3B | 20.43 GB | 23.0 GB | 0.1.6+ | Qwen 3.6 35B A3B MTP, +0.49 GB |

Chat acceleration uses a smaller draft model for speculative generation when the
catalog entry includes one and the acceleration snapshot is present. If the
draft model cannot be loaded, MLXtra falls back to the main model and marks the
generation as fallback/unavailable in the message metrics.

### Image

| Model | Download | Est. memory | Runtime | Capabilities |
| --- | ---: | ---: | --- | --- |
| FLUX.2-klein-4B | 23.74 GB | 13.0 GB | 0.1.0+ | Text-to-image and image editing |
| Ideogram 4 FP8 | 27.55 GB | 36.0 GB | 0.1.7+ | Text-to-image |
| Z-Image Turbo | 32.90 GB | 14.0 GB | 0.1.0+ | Text-to-image |

Image generation runs through the bundled `mflux` runtime. The current runtime
supports `flux2-klein-4b`, `ideogram-4-fp8`, and `z-image-turbo`.

### Speech

| Model | Download | Est. memory | Runtime | Notes |
| --- | ---: | ---: | --- | --- |
| Kokoro 82M 4-bit | 0.67 GB | 1.0 GB | 0.1.2+ | Fast lightweight speech generation |
| KugelAudio 0 Open | 18.69 GB | 19.0 GB | 0.1.0+ | Higher-capability speech generation |

### Music

| Model | Download | Est. memory | Runtime | Notes |
| --- | ---: | ---: | --- | --- |
| Magenta RealTime 2 Small | 1.42 GB | 3.0 GB | Music 0.1.7+ | Instrumental-only, real-time focused |
| Magenta RealTime 2 Base | 3.75 GB | 8.0 GB | Music 0.1.7+ | Instrumental-only, recommended on M5 Max, M3 Max, M2 Max, and M4 Pro |
| ACE-Step 1.5 Turbo | 10.09 GB | 4.0 GB | Music 0.1.0+ | Music generation with vocal/lyrics workflows |

Magenta RealTime 2 does not accept or generate lyrics. For vocal music with
lyrics, use ACE-Step instead. MLXtra recommends Magenta Base on the Macs listed
as real-time capable by Magenta's README (M5 Max, M3 Max, M2 Max, and M4 Pro),
and Small on other Apple Silicon Macs.

Large models are shown only on Macs where they are expected to fit comfortably.
Some model providers may require accepting model terms or signing in to Hugging
Face before downloads work.

## First Launch

On first launch, MLXtra starts setting up the local runtime in the background.
You can choose your first model while setup finishes. If the runtime is still
installing, the model download is queued and starts automatically once the
runtime is ready.

The runtime, model cache, conversations, and generated media stay on your Mac.
Generated files are saved under:

```text
~/Library/Application Support/MLXtra/GeneratedImages/
~/Library/Application Support/MLXtra/GeneratedSpeech/
~/Library/Application Support/MLXtra/GeneratedMusic/
```

## Build From Source

Clone the repository:

```bash
git clone https://github.com/mlxtra/mlxtra.git
cd mlxtra
```

Build the app bundle with Xcode:

```bash
xcodebuild -project MLXtra.xcodeproj -scheme MLXtra -configuration Debug build
```

Or build and launch the debug app:

```bash
Scripts/launch-debug-app.sh
```

Run the Swift test suite:

```bash
swift test
```

Python bridge and integration tests are documented in [AGENTS.md](AGENTS.md).

Release, runtime, notarization, and appcast workflows are documented in
[docs/RELEASE_WORKFLOW.md](docs/RELEASE_WORKFLOW.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, test commands, and
pull request expectations.

## Security

Please report vulnerabilities privately. See [SECURITY.md](SECURITY.md).

## License

MLXtra is released under the Apache License 2.0. See [LICENSE](LICENSE).

Third-party libraries, runtime packages, and model artifacts are licensed
separately by their respective owners. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Acknowledgments

- [MLX](https://github.com/ml-explore/mlx) by Apple
- [mlx-vlm](https://github.com/Blaizzy/mlx-vlm)
- [mlx-audio](https://github.com/Blaizzy/mlx-audio)
- [mflux](https://github.com/filipstrand/mflux)
- [ACE-Step](https://github.com/ace-step/ACE-Step)
- [Magenta RealTime](https://github.com/magenta/magenta-realtime)
