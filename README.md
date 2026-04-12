# MLXHub

A macOS-native GUI application for running and interacting with MLX (Machine Learning eXchange) models on Apple Silicon. Built with SwiftUI and Python bridges for seamless local AI model execution.

## Features

### Model Support
- **Vision-Language Models (VLM)**: Chat with vision models like LLaVA, Qwen2-VL
- **Text-to-Image**: Generate images with mflux (Flux-based models)
- **Image Editing**: Edit images with Flux2KleinEdit
- **Text-to-Speech**: Generate speech with KugelAudio
- **Text-to-Music**: Create music with ACE-Step 1.5

### Core Capabilities
- **Tool Calling**: Models can use tools/functions for enhanced capabilities
- **Streaming Responses**: Real-time chat responses with typing indicators
- **Model Management**: Download and cache models locally with progress tracking
- **Multi-turn Conversations**: Persistent chat history with context
- **Drag & Drop**: Easy image attachment for vision tasks

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon Mac (M1, M2, M3, M4)
- Xcode 15+ (for building)
- Python 3.12 (for runtime)

## Installation

### From Source

1. Clone the repository:
```bash
git clone git@github.com:omercelik/MLXHub.git
cd MLXHub
```

2. Open in Xcode:
```bash
open MLXHub.xcodeproj
```

3. Build and run (⌘+R)

### Runtime Setup

The application requires Python runtime bundles. Build them with:

```bash
./Scripts/build-runtime-bundle.sh
```

This will:
- Create Python virtual environments
- Install required packages (mlx-vlm, mlx-lm, mflux, acestep, etc.)
- Set up the runtime in `MLXHub/Resources/runtime/`

**Note**: The `acestep-venv` is required for music generation but is excluded from git (see `.gitignore`). You'll need to build it locally.

## Architecture

```
MLXHub/
├── MLXHub/                 # Main Swift source code
│   ├── Views/             # SwiftUI views
│   ├── ViewModels/        # Business logic
│   ├── Models/            # Data models
│   ├── Services/          # Core services
│   │   ├── Execution/     # Model execution engines
│   │   └── Runtime/       # Runtime management
│   └── Resources/         # Python bridges and runtime
│       ├── python_bridge.py    # Main Python bridge
│       ├── acestep_bridge.py   # ACE-Step music bridge
│       └── runtime/            # Python environments
├── Scripts/               # Build scripts
└── Package.swift         # Swift Package Manager
```

## Usage

### Chat Interface
- Start a new chat from the sidebar
- Type messages or use `/image <path>` to attach images
- Models with tool support can execute functions automatically

### Model Selection
- Click the model dropdown to switch between available models
- Models are downloaded automatically on first use
- Download progress is shown in the sidebar

### Image Generation
- Select an image generation model (e.g., Flux2Klein)
- Enter a prompt describing the desired image
- Adjust parameters like steps, guidance scale, etc.

### Music Generation
- Use ACE-Step models
- Provide a caption describing the music style
- Optional: Add lyrics for vocal generation

## Development

### Project Structure

- **SwiftUI Frontend**: Modern declarative UI with macOS-native look
- **Python Bridge**: `python_bridge.py` handles model execution
- **Async/Await**: Concurrent model loading and generation
- **Actors**: Thread-safe model registries

### Key Components

#### Python Bridge (`python_bridge.py`)
- Transparent proxy to mlx-vlm, mlx-lm, and other MLX libraries
- Supports hot-swapping between models
- JSON-based communication with Swift

#### Model Executors
- `VLMExecutor`: Vision-language model execution
- `ImageExecutor`: Text-to-image generation
- Specialized bridges for ACE-Step (music) and mflux (images)

#### Chat System
- `ChatViewModel`: Manages chat state and model interactions
- `Message`: Represents chat messages with tool calls
- `ToolUse`: Function calling infrastructure

### Adding New Models

1. Add model entry to `runtime-manifest.json`
2. Implement executor in `Services/Execution/`
3. Update model registry in `python_bridge.py`

## Configuration

Settings are accessible via `MLXHub → Settings`:
- Default model selection
- Output directories for generated files
- Advanced generation parameters

## Dependencies

### Swift
- SwiftUI (built-in)
- Foundation (built-in)

### Python (via bundled runtime)
- mlx-vlm: Vision-language models
- mlx-lm: Language models
- mflux: Flux image generation
- acestep: Music generation
- transformers: Model utilities

## Troubleshooting

### "No module named 'acestep'"
The acestep-venv must be built locally:
```bash
./Scripts/build-runtime-bundle.sh
```

### Model downloads fail
Check internet connection and Hugging Face access. Some models require authentication.

### Out of memory
Reduce model quantization or use smaller models. MLX automatically manages memory but large models may exceed available RAM.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Open a Pull Request

## License

[Add your license here]

## Acknowledgments

- [MLX](https://github.com/ml-explore/mlx) by Apple
- [mlx-vlm](https://github.com/Blaizzy/mlx-vlm) by Prince Canuma
- [mflux](https://github.com/argmaxinc/mflux) by Argmax
- [ACE-Step](https://github.com/ace-step/acestep) for music generation
