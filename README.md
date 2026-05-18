# MLXtra

MLXtra is a native macOS app for running local AI models on Apple Silicon with
[MLX](https://github.com/ml-explore/mlx). It brings chat, image generation,
speech generation, and music generation into one desktop app.

Models run locally on your Mac. The app downloads its verified runtime and the
models you choose after installation.

## Download

Download the latest notarized DMG from
[GitHub Releases](https://github.com/mlxtra/mlxtra/releases/latest).

Open the release page and download the `MLXtra-*.dmg` asset.

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon Mac
- Internet connection for the first runtime and model downloads
- Sufficient free disk space for selected models

Model sizes vary. Small chat models are a few GB; image and speech models can be
larger.

## First Run

On first launch, MLXtra starts setting up the local runtime in the background.
You can choose your first model while setup finishes. If the runtime is still
installing, the model download is queued and starts automatically once the
runtime is ready.

The runtime is installed under:

```text
~/Library/Application Support/MLXtra/runtimes/
```

Downloaded model files and generated media stay on your Mac.

## Features

- Chat with local models, including models that can understand images
- Generate images with FLUX.2 Klein
- Generate speech with KugelAudio
- Generate music with ACE-Step
- Manage model downloads from Settings
- Stream chat responses in real time
- Keep conversation history locally
- Receive app updates through Sparkle

## Screenshots

![Welcome screen](docs/assets/screenshots/welcome.png)

![Chat interface with image generation](docs/assets/screenshots/image.png)

![Speech generation](docs/assets/screenshots/speech.png)

![Music generation](docs/assets/screenshots/music.png)

![Tool selector](docs/assets/screenshots/web.png)

![Model management](docs/assets/screenshots/models.png)

## Models

MLXtra ships with a curated model catalog. The current catalog includes:

- Qwen 3.5
- Qwen 3.5 Mini
- Gemma 4
- FLUX.2 Klein
- KugelAudio 0 Open
- ACE-Step 1.5 Turbo

Some model providers may require accepting model terms or signing in to Hugging
Face before downloads work.

## Generated Files

Generated media is saved in the app support directory:

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

## Project Layout

```text
MLXtra/
├── MLXtra/
│   ├── Models/
│   ├── Services/
│   │   ├── AppUpdate/
│   │   ├── Execution/
│   │   └── Runtime/
│   ├── ViewModels/
│   ├── Views/
│   └── Resources/
│       ├── python_bridge.py
│       ├── acestep_bridge.py
│       └── stable-channel.json
├── Scripts/
├── Tests/
└── docs/
```

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
- [mflux](https://github.com/filipstrand/mflux)
- [ACE-Step](https://github.com/ace-step/ACE-Step)
