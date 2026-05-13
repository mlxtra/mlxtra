# MLXtra Python/Shell/CI Prepublish Review

## Scope

Reviewed read-only slice:

- `MLXtra/Resources/*.py`
- `MLXtra/Resources/runtime/macos-arm64/*.py`
- `Scripts/*` release/build/test scripts
- top-level `test_*.py`
- `Tests/PythonTests/*.py`
- `.github/workflows/ci.yml`

Focus areas: false-positive tests, subprocess deadlocks, bad exit codes, portability, clone-and-run behavior, publish readiness, missing coverage, duplicated logic.

## Counts By Severity

- P0: 1
- P1: 4
- P2: 4
- P3: 2
- Total P0-P3 findings: 11

## P0

### P0-1: Main music route can hang forever waiting for a sentinel the child never emits

- File: `MLXtra/Resources/python_bridge.py:1029`
- Confidence: high
- Why it matters: `_forward_music_request()` reads the persistent ACE-Step child with blocking `readline()` until it sees `__DONE__`, EOF, or process exit. The child script `MLXtra/Resources/acestep_bridge.py` emits JSON events and then returns from `generate_music_once()`, but it never prints `__DONE__` and, as a one-shot script, exits after one request. In the persistent path, the parent can block waiting for another line after `chat.completion.complete`, especially because `stderr` is merged into stdout and non-JSON output is ignored. This is a publish blocker for `music.generate` through `python_bridge.py`.
- Concrete fix: make the protocol completion-driven instead of sentinel-dependent. Break on `chat.completion.complete` or `error` for the current request ID, or update `acestep_bridge.py` to run a real keep-alive loop that prints a documented sentinel after every request. Add a test where the helper emits `chat.completion.complete` without `__DONE__` and assert `_forward_music_request()` returns.

## P1

### P1-1: `acestep_bridge.py` reports failures over JSON but exits with code 0

- File: `MLXtra/Resources/acestep_bridge.py:91`
- Confidence: high
- Why it matters: validation failures such as missing prompt, model initialization failure, generation failure, and unhandled exceptions only emit `{"type":"error"}` and then return from `main()` normally. Clone-and-run scripts, release smoke tests, and subprocess callers that gate on exit status can mark a failed bridge invocation as successful.
- Concrete fix: have `generate_music_once()` return a success boolean or raise a typed exception, and make `main()` exit `1` when any error JSON is emitted. Keep JSON output unchanged for Swift, but make direct CLI and test harness behavior fail-fast.

### P1-2: CI explicitly skips runtime validation and never runs the real bridge/runtime path

- File: `.github/workflows/ci.yml:43`
- Confidence: high
- Why it matters: the app build step sets `MLXTRA_SKIP_RUNTIME_VALIDATION=1`, Python checks only compile or mocked unit behavior, and no CI job runs `validate-runtime-bundle.sh` against a real or cached runtime. Broken runtime packaging, missing helper files, bad bundled interpreter links, and download-helper dependency drift can ship.
- Concrete fix: add a separate release-readiness job or scheduled/manual workflow that runs `Scripts/validate-runtime-bundle.sh` without `MLXTRA_SKIP_RUNTIME_VALIDATION`, then runs at least lightweight bridge control routes against the built app bundle. If the full runtime is too heavy for every PR, gate publish tags on it.

### P1-3: Integration suites can pass while skipping every model-backed workflow

- File: `test_all_models_integration.py:230`
- Confidence: high
- Why it matters: when local Hugging Face snapshots or ACE-Step checkpoints are missing, `missing_model_result()` returns `None`; each model test converts that to `True`, and the summary reports pass with skips unless `MLXTRA_REQUIRE_ALL_MODELS=1`. A prepublish run without that environment variable can report "All tests passed!" while chat, image, speech, and music generation were never exercised.
- Concrete fix: make prepublish scripts set `MLXTRA_REQUIRE_ALL_MODELS=1`, or add a `--strict` CLI flag that is required for release gates. Also print a final nonzero exit when any required model-backed test was skipped in prepublish mode.

### P1-4: Main-bridge music integration test can deadlock because stderr is not drained

- File: `test_music_integration.py:580`
- Confidence: high
- Why it matters: `test_main_bridge_music_forwarding()` starts `python_bridge.py` with `stderr=PIPE` but only reads stdout until completion. Model/runtime imports and generation can write enough stderr to fill the pipe, blocking the child before it emits the expected stdout completion. That produces a false timeout even when product code would work, or hides the actual error until after termination.
- Concrete fix: drain stderr concurrently with a thread or selector, matching `test_all_models_integration.py`'s `run_bridge_session()` approach. Prefer reusing one subprocess runner helper across the integration scripts.

## P2

### P2-1: The unused one-shot ACE forwarding path has better deadlock handling than the live persistent path

- File: `MLXtra/Resources/python_bridge.py:1059`
- Confidence: high
- Why it matters: `_forward_acestep_subprocess()` uses selectors to drain stdout and stderr separately, but `handle_music_generation()` now calls `_ensure_music_subprocess()` and `_forward_music_request()` instead. The tested selector path is effectively dead code for normal isolated ACE-Step usage, so tests can pass while the production path has the P0 sentinel/blocking bug.
- Concrete fix: either route production music generation through `_forward_acestep_subprocess()` again, or give the persistent implementation equivalent selector-based draining and protocol tests. Remove or clearly mark the unused path after coverage is moved.

### P2-2: Unit test claims stderr draining but the helper writes stderr into stdout

- File: `Tests/PythonTests/test_python_bridge.py:703`
- Confidence: high
- Why it matters: `test_forward_music_request_drains_stderr_output` exercises `_ensure_music_subprocess()`, which starts the helper with `stderr=subprocess.STDOUT`. The test name and assertion imply separate stderr-drain safety, but the production path is only reading one combined stdout pipe. This leaves no test coverage for a child with a distinct stderr pipe and can mask future regressions.
- Concrete fix: rename the test to reflect merged stdout/stderr behavior, and add a separate test for whichever implementation is actually used in production. If separate pipes are desired, change `_ensure_music_subprocess()` to use `stderr=PIPE` plus selector draining.

### P2-3: Runtime build script downloads Python without checksum verification

- File: `Scripts/build-runtime-bundle.sh:100`
- Confidence: high
- Why it matters: the release runtime builder downloads a Python `.pkg` over HTTPS and uses a resumable cache, but does not verify a pinned SHA-256 or signature before expanding it. A corrupted partial cache or compromised download path can produce a poisoned runtime bundle.
- Concrete fix: add a pinned `PYTHON_PKG_SHA256` in `Scripts/runtime-dependencies.sh`, verify the cached/downloaded file with `shasum -a 256`, and delete/retry on mismatch before `pkgutil --expand`.

### P2-4: Release asset script accepts missing option values until shell errors

- File: `Scripts/prepare-release-assets.sh:102`
- Confidence: high
- Why it matters: options such as `--repo`, `--channel`, `--output-dir`, `--catalog-version`, and `--runtime-version` read `$2` without validating it. With `set -u`, a trailing option produces an unhelpful unbound-variable failure; with another option as the next token, it silently consumes that option as a value. This hurts clone-and-run release workflows.
- Concrete fix: copy the `require_option_value()` helper pattern from `Scripts/build-runtime-bundle.sh` and use it for every option that requires a value.

## P3

### P3-1: Top-level probe script has user-facing Unicode and does not mirror bridge environment

- File: `test_bridge.py:25`
- Confidence: medium
- Why it matters: this script prints emoji/non-ASCII output and only prepends site-packages; it does not clear conflicting Python env vars or set `PYTHONHOME` like the Swift executor and integration tests. It is easy for contributors to run it and get a misleading pass or fail unrelated to the packaged app.
- Concrete fix: either remove it from the prepublish surface in favor of `test_all_models_integration.py`, or update it to use the same environment construction and ASCII-only output as the other scripts.

### P3-2: Normalization tests execute a slice of bridge source text instead of importing the shared helper

- File: `test_music_integration.py:290`
- Confidence: medium
- Why it matters: `exec(bridge_code.split("def generate_music_once")[0], namespace)` is brittle and can break if imports or function ordering change. It also tests an implementation detail of `acestep_bridge.py` rather than the shared source of truth in `bridge_utils.normalize_music_model_id()`.
- Concrete fix: import `bridge_utils.normalize_music_model_id` from the app resources directly and test that. Do the same in `test_all_models_integration.py`.

## Low-Confidence Notes

### LC-1: `hf_download_helper.py` only hashes large LFS files when explicitly enabled

- File: `MLXtra/Resources/runtime/macos-arm64/hf_download_helper.py:120`
- Confidence: low
- Why it matters: by default, files larger than 64 MiB are checked by size but not SHA-256. Size checks catch incomplete downloads but not same-size corruption. This may be an intentional performance tradeoff for large model weights.
- Concrete fix: for release/prepublish validation, set `MLXTRA_VERIFY_LARGE_FILE_HASHES=1` or add a sampled/hash-once cache so full integrity is available without repeated slow hashing.

### LC-2: `check-swift-coverage.sh` excludes major runtime orchestration from the coverage gate

- File: `Scripts/check-swift-coverage.sh:12`
- Confidence: low
- Why it matters: the coverage gate excludes `VLMExecutor.swift`, `RuntimeManager.swift`, `ModelDownloadManager.swift`, and `DownloadHelperProcessRunner.swift`, which are exactly the Swift surfaces coordinating these Python scripts. This may be intentional for deterministic core coverage, but it lowers confidence in prepublish runtime behavior.
- Concrete fix: keep the core coverage gate, but add a second non-percentage integration gate for runtime/download/executor behavior, or track those files with targeted tests outside the coverage threshold.
