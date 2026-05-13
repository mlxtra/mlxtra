# Contributing to MLXtra

Thanks for helping improve MLXtra. The project is a native macOS app with SwiftUI
UI, Swift services, and Python bridge/runtime code for local MLX model execution.

## Development Setup

Requirements:

- macOS 14 or later
- Apple Silicon Mac
- Xcode 15 or later
- Python 3.12 for runtime work

Build the app with Xcode:

```bash
xcodebuild -project MLXtra.xcodeproj -scheme MLXtra -configuration Debug build
```

Do not use `swift build` as the main app build check; it does not produce the
full `.app` bundle with embedded resources.

## Tests

Run the lightweight checks before opening a pull request:

```bash
Scripts/validate-release-metadata.py --allow-runtime-placeholders
Scripts/check-swift-coverage.sh
python3 -m py_compile MLXtra/Resources/python_bridge.py MLXtra/Resources/acestep_bridge.py
```

The Swift coverage script enforces 80% line coverage for deterministic core
Swift code. It still runs the full Swift test suite, but the threshold excludes
UI views, app entrypoints, subprocess/runtime orchestration, network adapters,
cache wrappers, renderer adapters, and debug instrumentation.

For bridge changes, also run:

```bash
cd Tests/PythonTests
PYTHONPATH=../../../MLXtra/Resources python3 test_python_bridge.py -v
PYTHONPATH=../../../MLXtra/Resources python3 test_acestep_bridge.py -v
```

Integration tests that exercise Metal, local models, or generated media may
require local runtime/model setup and are not expected to pass on every machine.
To force a full local model gate and allow missing models to be downloaded first,
run:

```bash
MLXTRA_ALLOW_MODEL_DOWNLOADS=1 MLXTRA_REQUIRE_ALL_MODELS=1 python3 test_all_models_integration.py
```

## Pull Requests

- Keep changes focused and explain the user-visible behavior.
- Match existing SwiftUI, Swift, and Python style.
- Include tests for behavior changes when practical.
- Do not commit model weights, generated media, local runtime environments, or
  machine-specific paths.
- Update release metadata or notices when changing bundled dependencies.

## Licensing

By contributing to MLXtra, you agree that your contribution is licensed under
the Apache License 2.0, the same license as the project.
