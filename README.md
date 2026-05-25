# MLXtra

**Local AI creation for Mac, beyond chat.**

MLXtra is a native Apple Silicon app for local AI creation. It runs chat,
vision, image, speech, and music models on your Mac with
[MLX](https://github.com/ml-explore/mlx), without turning setup into a model
server project.

[Download MLXtra 1.0.9 DMG](https://github.com/mlxtra/mlxtra/releases/download/app-1.0.9/MLXtra-1.0.9.dmg)
| [Watch demo](https://raw.githubusercontent.com/mlxtra/mlxtra/main/docs/assets/demo/MLXtra.mp4)
| [View releases](https://github.com/mlxtra/mlxtra/releases)
| [Build from source](#build-from-source)

![MLXtra home screen](docs/assets/screenshots/welcome.png)

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

<video src="https://raw.githubusercontent.com/mlxtra/mlxtra/main/docs/assets/demo/MLXtra.mp4" controls width="100%" title="MLXtra demo"></video>

[Watch the demo video](https://raw.githubusercontent.com/mlxtra/mlxtra/main/docs/assets/demo/MLXtra.mp4)

## What You Can Do

- Chat with local vision-language models and attach images
- Generate images with FLUX.2 Klein or Z-Image Turbo
- Generate speech with KugelAudio or Kokoro
- Generate music with ACE-Step
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

MLXtra ships with a curated model catalog:

- **Chat and vision:** Qwen 3.5, Qwen 3.6, and Gemma 4 variants
- **Image:** FLUX.2-klein-4B and Z-Image Turbo
- **Speech:** KugelAudio 0 Open and Kokoro 82M 4-bit
- **Music:** ACE-Step 1.5 Turbo

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
