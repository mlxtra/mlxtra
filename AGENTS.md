# MLXHub

## Quick Start (for developers)

### Building the App
```bash
# IMPORTANT: Always use xcodebuild, NOT swift build
# xcodebuild creates the full .app bundle with embedded resources
xcodebuild -project MLXHub.xcodeproj -scheme MLXHub -configuration Debug build
```

### Running the App
```bash
# After building
open /Users/$USER/Library/Developer/Xcode/DerivedData/MLXHub-*/Build/Products/Debug/MLXHub.app

# Or from Xcode: Cmd+R
```

### Running Tests

**Swift Tests (172 tests):**
```bash
swift test
```

**Python Bridge Tests (18 tests):**
These bridge tests can exercise runtime imports, local caches, and subprocess behavior. In Codex, run all bridge tests outside the sandbox with escalation; sandboxed runs can report false failures for non-code reasons.

```bash
cd Tests/PythonTests
PYTHONPATH=../../../MLXHub/Resources python3 test_python_bridge.py -v
PYTHONPATH=../../../MLXHub/Resources python3 test_acestep_bridge.py -v
```

**Integration Tests (end-to-end):**
These tests exercise the bundled app runtime, Metal, local model files, and output directories under `~/Music` / `~/Pictures`. In Codex, run them outside the sandbox with escalation; sandboxed runs can report false MLX/Metal crashes.

```bash
# Music generation only (fast - ~15s)
python3 test_music_integration.py

# All model types (slow - ~5 min)
python3 test_all_models_integration.py
```

---

## When Something Breaks

### Music Generation Not Working

**1. Check if model files exist:**
```bash
ls ~/Library/Application\ Support/MLXHub/checkpoints/
# Should show: acestep-v15-turbo, vae, Qwen3-Embedding-0.6B, acestep-5Hz-lm-1.7B
```

**2. Run integration test:**
Run this outside the Codex sandbox with escalation so ACE-Step can access Metal and write generated audio.

```bash
python3 test_music_integration.py
```

**3. Check for Metal validation errors in console:**
- Look for: `validateComputeFunctionArguments: failed assertion`
- If found, the fix is in `VLMExecutor.swift` - ensure `MTL_DEBUG_LAYER` is set to `"0"`

**4. Check Python bridge syntax:**
```bash
python3 -m py_compile MLXHub/Resources/python_bridge.py
python3 -m py_compile MLXHub/Resources/acestep_bridge.py
```

### Model Not Found Errors

**Check the model ID normalization:**
- Swift passes: `ACE-Step/acestep-v15-turbo-continuous`
- ACE-Step expects: `acestep-v15-turbo`
- The fix is in `_normalize_music_model_id()` in both bridge files

### Build Issues

**Resources not found:**
- Did you use `swift build` instead of `xcodebuild`?
- Check: `ls DerivedData/.../MLXHub.app/Contents/Resources/`

**Tests failing:**
- Run tests individually: `swift test --filter TestName`
- Check Python environment: `which python3` should be system Python, not conda

---

## Key Files Reference

```
MLXHub/
├── Services/
│   ├── Execution/VLM/VLMExecutor.swift    # Main Python bridge executor
│   │                                        - Spawns Python subprocess
│   │                                        - Handles streaming responses
│   │                                        - Sets Metal env vars (MTL_DEBUG_LAYER)
│   └── Runtime/
│       ├── RuntimeManager.swift           # Python runtime lifecycle
│       └── ModelDownloadManager.swift     # Model download orchestration
├── ViewModels/ChatViewModel.swift         # Chat UI logic
├── Models/
│   ├── AIModel.swift                      # Model definitions (VLM, LLM, Image, Audio, Music)
│   ├── Chat.swift                         # Chat data models
│   └── Tool.swift                         # Tool calling models
└── Resources/
    ├── python_bridge.py                   # Main Python bridge
    │                                        - Loads MLX-VLM, FLUX, TTS models
    │                                        - Handles chat.completions, image.generate, audio.speech
    │                                        - Spawns acestep_bridge subprocess for music
    ├── acestep_bridge.py                  # ACE-Step music generation bridge
    │                                        - Runs in isolated subprocess (package conflicts)
    └── runtime/macos-arm64/               # Python runtimes
        ├── venv/                          # Main venv (MLX-VLM, FLUX, TTS)
        └── acestep-venv/                  # ACE-Step venv (torch, incompatible packages)
```

---

## Model Types & Flow

| Model Type | Swift Backend | Python Bridge | Handler Function | Output Path |
|------------|--------------|---------------|------------------|-------------|
| VLM/LLM | `.vlm`/`.llm` | `python_bridge.py` | `handle_chat_completion()` | - |
| Image | `.image` | `python_bridge.py` | `handle_image_generation()` | `~/Pictures/MLXHub/` |
| Audio/TTS | `.audio` | `python_bridge.py` | `handle_audio_speech()` | `~/Music/MLXHub/` |
| Music | `.music` | `acestep_bridge.py` (subprocess) | `generate_music_once()` | `~/Music/MLXHub/` |

**Note:** Music uses a subprocess because ACE-Step requires incompatible package versions (torch) that conflict with the main MLX stack.

---

## Debugging Tips

### Enable Debug Logging

In `python_bridge.py` and `acestep_bridge.py`:
```python
def log_debug(msg):
    print(msg, file=sys.stderr, flush=True)  # Uncomment this line
```

### Test Individual Components

**Test ACE-Step directly:**
```bash
cd ~/Library/Developer/Xcode/DerivedData/MLXHub-*/Build/Products/Debug/MLXHub.app/Contents/Resources
ACESTEP_CHECKPOINTS_DIR=~/Library/Application\ Support/MLXHub/checkpoints \
  runtime/macos-arm64/acestep-venv/bin/python acestep_bridge.py << 'EOF'
{"model": "ACE-Step/acestep-v15-turbo-continuous", "messages": [{"role": "user", "content": "test"}], "parameters": {"caption": "test", "duration": 5, "inference_steps": 4}}
EOF
```

### Common Issues

**"Model not fully initialized"**
- Caused by `initialize_service()` failing silently
- Check: `python_bridge.py` line ~162 should check `init_result[1]` before continuing

**"Unknown DiT model"**
- Model ID not normalized
- Check: `_normalize_music_model_id()` in bridge files

**Metal validation crash**
- Add to `VLMExecutor.swift` `setupEnvironment()`:
  ```swift
  cleanEnv["MTL_DEBUG_LAYER"] = "0"
  cleanEnv["MTL_SHADER_VALIDATION"] = "0"
  ```

---

## Development Guidelines

### Before Implementing Changes

**State your assumptions explicitly.** If uncertain, ask questions first.

- If multiple interpretations exist, present them - don't pick silently
- If a simpler approach exists, mention it
- If something is unclear, stop and clarify

**Run tests before and after changes:**
```bash
# Swift tests
swift test --filter TestName

# Python bridge tests for bridge changes
# In Codex, run these outside the sandbox with escalation.
cd Tests/PythonTests
PYTHONPATH=../../../MLXHub/Resources python3 test_python_bridge.py -v
PYTHONPATH=../../../MLXHub/Resources python3 test_acestep_bridge.py -v
cd ../..

# Integration test for the feature
# In Codex, run this outside the sandbox with escalation.
python3 test_music_integration.py  # or test_all_models_integration.py
```

### Simplicity First

- Minimum code that solves the problem
- No speculative features
- No abstractions for single-use code
- Match existing style, even if you'd do it differently
- If you notice unrelated dead code, mention it - don't delete it

### Surgical Changes

**Touch only what you must:**
- Don't "improve" adjacent code, comments, or formatting
- Don't refactor things that aren't broken
- Remove imports/variables/functions that YOUR changes made unused
- Every changed line should trace directly to the request

### Premium UI Standard

**Keep the interface feeling premium:**
- Prefer calm, minimal surfaces over explanatory text, clutter, or debug-like copy
- Put technical recommendations, model details, and diagnostics in settings or dedicated status surfaces, not the homepage
- Use concise user-facing copy; remove text that does not directly help the current task
- Keep motion subtle, purposeful, and tied to state such as focus, loading, streaming, or generation
- Preserve spacing, alignment, typography, and visual hierarchy when adding controls
- Avoid making the homepage feel like a configuration screen; it should invite action

### Goal-Driven Execution

**Transform tasks into verifiable goals:**
- "Fix music generation" → "Run test_music_integration.py, make it pass"
- "Add feature X" → "Test that X works via integration test"

**For multi-step tasks, state a brief plan:**
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

---

## Integration Test Architecture

The integration tests simulate exactly how Swift uses the bridges:

1. **Chat/VLM tests** use persistent subprocess (model stays loaded)
   - Send `init` request
   - Wait for `model.loaded`
   - Send `chat.completions`
   - Receive streaming chunks + completion

2. **Image/Audio/Music tests** use one-shot subprocess (no persistence needed)
   - Send single request
   - Get result
   - Process exits

Run them before committing changes to Python bridge files.
