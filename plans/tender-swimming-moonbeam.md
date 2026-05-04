# Python Bridge Performance & Stability Fixes

## Context

Deep inspection of the Python bridge system (Python subprocess + Swift Process/Pipe management + chat orchestration) revealed 15 issues across 8 files. The Python bridge (`python_bridge.py`) runs as a long-lived subprocess spawned by `VLMExecutor.swift`, communicating via JSON-line protocol over stdin/stdout. While the architecture is sound, several resource-leak, crash, and deadlock paths were identified that could cause process leaks, UI hangs, or crashes under edge conditions.

## Issues Summary

| # | Severity | File | Issue |
|---|----------|------|-------|
| H1 | HIGH | VLMExecutor.swift | No `deinit` — orphaned subprocess if released without `terminate()` |
| H2 | HIGH | ModelDownloadManager.swift | Missing SIGKILL fallback + processes dict leak in `stop()` |
| M1 | MEDIUM | RuntimeManager.swift | `waitUntilExit()` blocks @MainActor synchronously |
| M2 | MEDIUM | python_bridge.py | `main()` has no cleanup — music subprocess never terminated on exit |
| M3 | MEDIUM | ChatServices.swift | `writeQueue.sync {}` in deinit could deadlock |
| M4 | MEDIUM | ModelDownloadManager.swift | Stderr readability handlers lack `[weak self]` |
| L1 | LOW | ChatViewModel.swift | Fire-and-forget terminate in `cancelGeneration()` |
| L2 | LOW | ChatViewModel.swift | No overall generation timeout in `processStream` |
| L3 | LOW | ChatViewModel+Messages.swift | Fragile string-based `CancellationError` check |
| L4 | LOW | VLMExecutor.swift | stdin closed before `process.terminate()` in `terminate()` |
| L5 | LOW | python_bridge.py | `assert` statements stripped under `python -O` |
| L6 | LOW | RuntimeManager.swift | Force-unwrap on `FileManager.default.urls(...).first!` |
| L7 | LOW | VLMExecutor.swift | Stderr readability handler has no explicit EOF detection |
| L8 | LOW | BridgeProtocolSequenceTests.swift | Test helper `terminate()` missing kill/wait and pipe cleanup |

## Implementation Plan

### Group 1 — VLMExecutor.swift (H1, L4, L7)

**File:** `MLXHub/Services/Execution/VLM/VLMExecutor.swift`

#### H1: Add `deinit` (after line 51, `init()` closing brace)
Prevents orphaned Python subprocess on unexpected deallocation. Since `deinit` cannot be `async`, uses a best-effort fire-and-forget terminate + 3-second delayed SIGKILL via `DispatchQueue.asyncAfter`.

#### L4: Reorder terminate() — terminate process BEFORE closing stdin
Move `stdinToClose?.fileHandleForWriting.closeFile()` to after the terminate/kill/wait block. Keeps stdin open during SIGTERM delivery so the Python process receives clean termination.

#### L7: Add explicit EOF guard in stderr handler (line ~690)
Add `guard !data.isEmpty else { return }` before string decoding, matching the stdout handler pattern.

### Group 2 — ModelDownloadManager.swift (H2, M4)

**File:** `MLXHub/Services/Runtime/ModelDownloadManager.swift`

#### H2: Add SIGKILL fallback + processes dict cleanup in `stop()` (line ~394)
After `process.terminate()`, schedule a 3-second delayed `SIGKILL`. Add cleanup path for `!process.isRunning` case to prevent `processes[modelId]` dictionary leak.

#### M4: Add `[weak errorLog]` to stderr readability handlers (lines ~471, ~574)
Match the `[weak self]` pattern already used in stdout handlers.

### Group 3 — RuntimeManager.swift (M1, L6)

**File:** `MLXHub/Services/Runtime/RuntimeManager.swift`

#### M1: Reorder `validatePythonImports()` — read pipes before `waitUntilExit()`
Move `readDataToEndOfFile()` on both pipes to before `process.waitUntilExit()`. Prevents pipe-buffer deadlock and minimizes blocking time on @MainActor.

#### L6: Replace force-unwrap with nil-coalescing fallback (line 54)
Change `.first!` to `?? FileManager.default.homeDirectoryForCurrentUser`, matching the pattern in `ChatViewModel.swift:265`.

### Group 4 — ChatViewModel.swift (L1, L2)

**File:** `MLXHub/ViewModels/ChatViewModel.swift`

#### L1: Store termination task in `cancelGeneration()` (line 502)
Change `Task { await vlmExecutor.terminate() }` to `generationTask = Task { await vlmExecutor.terminate() }` so the task is observable and gets cancelled when a new generation starts.

#### L2: Add 5-minute overall timeout to `processStream` (after line 1005)
Create a timeout `Task` that sleeps for 300 seconds, then calls `vlmExecutor.terminate()` if the stream hasn't completed. Cancel the timeout task when the stream loop exits.

### Group 5 — ChatServices.swift (M3)

**File:** `MLXHub/ViewModels/ChatServices.swift`

#### M3: Replace `writeQueue.sync {}` with `writeQueue.async {}` in deinit (line 118)
Prevents deadlock if deinit is called from within the write queue (e.g. from a save completion closure).

### Group 6 — ChatViewModel+Messages.swift (L3)

**File:** `MLXHub/ViewModels/ChatViewModel+Messages.swift`

#### L3: Remove fragile string-based CancellationError check (line 228)
Replace `error is CancellationError || errorDesc.contains("CancellationError") || (error as NSError).code == NSUserCancelledError` with just `error is CancellationError`. All callers already check `Task.isCancelled` before reaching this function.

### Group 7 — python_bridge.py (M2, L5)

**File:** `MLXHub/Resources/python_bridge.py`

#### M2: Add `finally: _cleanup()` to `main()` (line 1277)
Wrap the main `for line in sys.stdin` loop in `try/finally` block. `_cleanup()` terminates `_music_process` via `_terminate_child()`.

#### L5: Replace `assert child.stdin/stdout is not None` with explicit `if/raise RuntimeError`
At lines 953, 960, 1009. Ensures checks work regardless of `python -O` flag.

### Group 8 — BridgeProtocolSequenceTests.swift (L8)

**File:** `Tests/MLXHubTests/BridgeProtocolSequenceTests.swift`

#### L8: Add proper kill/wait + pipe cleanup to `PersistentBridgeSession.terminate()` (line ~285)
Add 2-second wait after `terminate()`, followed by `SIGKILL` if still running. Close stdout/stderr read handles.

## Execution Order

```
Group 1 (VLMExecutor)        ── no deps, apply first
Group 2 (ModelDownloadManager)─ independent
Group 3 (RuntimeManager)     ── independent
Group 5 (ChatServices)       ── independent
Group 4 (ChatViewModel)      ── depends on Group 1 correctness
Group 6 (ChatViewModel+Msg)  ── independent
Group 7 (python_bridge.py)   ── independent of Swift changes
Group 8 (Tests)              ── apply last
```

## Verification

1. **Run existing test suite** after each group — all tests must pass unchanged
2. **Check for orphaned processes** — after cancelling a generation, verify via `ps aux | grep python` that the bridge process terminates
3. **Test cancel/restart cycles** — rapid cancel-and-resend to ensure no race conditions
4. **Test deallocation paths** — verify VLMExecutor deinit fires without crashing
5. **Python bridge cleanup** — terminate the app and verify `_cleanup()` runs (check logs)
6. **Pipe closure ordering** — verify SIGTERM is delivered before stdin closes
