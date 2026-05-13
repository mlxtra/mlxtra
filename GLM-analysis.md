# MLXtra Improvement Analysis

## 1. ~Conversation Persistence Debounce~ — DONE

Removed 9 hot-path `persistConversationHistory()` calls. Persistence now only fires at stream end or on user actions.

---

## 2. ChatViewModel is a 1729-line God Object

**Problem:** `ChatViewModel.swift` handles conversation CRUD, persistence, all 5 tool execution flows, stream processing, model download gating, music intent state, menu toggling, and contains `ChatStore` as a private inner class.

**Improvement ideas:**
- **Extract services:** `ConversationService` (CRUD + persistence), `ToolExecutionService` (web search, image, speech, music), `StreamProcessor` (token buffering, rendering, finalization)
- **Extract `ChatStore`** to its own file — it's a 115-line persistence layer buried inside the ViewModel
- **Protocol-based dependency injection** — `ChatViewModel` currently creates `VLMExecutor`, `RuntimeManager`, `MCPWebSearchService` internally, making testing impossible without real subprocesses
- **Eliminate 3 near-identical tool execution methods** — `executeImageGenerationToolCall`, `executeSpeechGenerationToolCall`, `executeMusicGenerationToolCall` all follow the same pattern: check download → parse args → show tool call → execute request → consume stream → append tool result. They could share a generic `executeMediaToolCall(type:backend:...)` with a parameterized config struct

---

## 3. Dynamic Model Registry

**Problem:** `AIModel` is a hardcoded enum with 3 cases. Model IDs are hardcoded strings scattered across `ChatViewModel` (`imageGenerationModelId`, `speechGenerationModelId`, `musicGenerationModelId`). Adding a model requires touching `AIModel`, `DownloadableModel.embedded`, `RuntimeManager.estimatedModelSize`, and the ViewModel constants.

**Improvement ideas:**
- **Make `AIModel` data-driven** — load model catalog from a JSON manifest (bundled or fetched) that lists model IDs, backends, specs, and download sizes
- **Single source of truth** — `DownloadableModel.embedded` already duplicates `AIModel.allCases`; merge them into one registry
- **Remove the 3 hardcoded model ID constants** from `ChatViewModel` — they should come from the model registry
- **Allow user-added custom models** — a "Custom Model" option where they paste an HF model ID and select a backend type

---

## 4. Swift-Python Bridge: No Request Correlation

**Problem:** The bridge uses a single stdin/stdout channel with no request IDs. If two requests were ever in flight (not currently possible, but the architecture doesn't prevent it), responses couldn't be correlated. The `readabilityHandler` is replaced for each phase (ready → model load → response), which is fragile.

**Improvement ideas:**
- **Add request IDs** to every message (both directions), so responses can be matched
- **Allow pipelining** — don't block on model load while the stdin channel is idle
- **Use a single persistent stdout handler** with a dispatcher that routes by request ID, instead of swapping handlers
- **Add a graceful shutdown protocol** — currently the app sends SIGTERM/SIGKILL; a `{"type": "shutdown"}` message would let the process flush and exit cleanly
- **Add per-request timeouts** in the Python bridge (e.g., 5 min for generation, 10 min for model load)

---

## 5. Duplicate & Dead Code

**Problems found:**
- **`ChatInputView.swift`** — appears to be a deprecated precursor to `ComposerView.swift` (simpler UI, different keyboard shortcut)
- **`ToolSelectorView` and `ModelSelectorView`** in `MainContentView.swift` duplicate `ToolSelectorInline` and `ModelSelectorInline` in `ComposerView.swift`
- **`BridgeLineBuffer`** (VLMExecutor) and `DownloadLineBuffer` (ModelDownloadManager) are functionally identical
- **`_normalize_music_model_id()`** is duplicated across `python_bridge.py` and `acestep_bridge.py`
- **`stringifyJSON()`** is duplicated in `MCPWebSearchService.swift` (twice)
- **Stray root files:** `=0.20.0`, `=0.21.0`, `=0.4.0`, `=1.24.0`, `=4.40.0`, `=10.0.0` are pip artifact files from pip install output being captured as files

**Improvement:** Delete dead views, extract shared line buffer to a utility, dedup Python helpers into a shared module, delete the stray `=` files

---

## 6. UI/UX Missing Features

| Gap | Fix |
|-----|-----|
| Chat rename button does nothing | Implement inline editing in sidebar |
| Voice input mic button has empty action | Implement or remove |
| No image lightbox/fullscreen view | Add click-to-expand overlay |
| Audio playback has no seek/progress | Add slider + waveform |
| No user-adjustable temperature/top-p | Add parameter toggles in composer or settings |
| No system prompt customization | Add a "System Instructions" settings field |
| `enableThinking` is false for all models | Enable for Qwen 3.5 (supports `<think>` tags) |
| No "Edit" for re-sending a message | Add edit/regenerate on user messages |
| No conversation export | Add "Export as Markdown" or "Share" |
| Integration tests are in root, not Tests/ | Move to `Tests/PythonTests/` |

---

## 7. Resilience & Error Handling

**Problems:**
- `VLMExecutor.maxRetries = 1` — only 1 retry on process crash
- No Python process health check between requests
- MCP web search has no timeout on `URLSession` requests
- Python tracebacks are surfaced raw to users (e.g., `"❌ Python Error:\nTraceback..."`)
- `ModelDownloadManager` has no retry-with-backoff
- `contextMessages` silently truncates to 20 messages with no user indication

**Improvement ideas:**
- Increase retries to 2-3 with exponential backoff
- Add a periodic ping/health check or piggyback on idle time
- Set `URLSessionConfiguration.timeoutIntervalForResource` for MCP requests
- Sanitize Python errors — show only the last exception message, log the full traceback to stderr
- Add a "context overflow" indicator when conversations approach the limit

---

## 8. Image Loading Performance

**Problem:** `MessageBubbleView` calls `NSImage(contentsOf: imageURL)` synchronously on every render. For generated images (which can be 1024x1024 PNGs), this loads from disk every time the view appears.

**Improvement ideas:**
- Add an `AsyncImage`-style loader with an `NSCache` or `ImageCache` actor
- Generate thumbnails for chat display and only load full-res on expand
- Use `ImageRenderer` or pre-decoded representations

---

## 9. Thinking Mode Disabled

**Problem:** `AIModel.enableThinking` returns `false` for all models, and the `chatTemplateKwargs` only apply to Qwen models. Qwen 3.5 supports `<think>` reasoning, and the UI already has `ThinkingView` + `extractThinking`/`extractMainContent` parsers — but the feature is gated off.

**Improvement:** Set `enableThinking = true` for Qwen models, add a toggle in the UI (per-chat or per-model), and ensure the streaming renderer handles partial `<think>` content properly.

---

## 10. Concurrency Model

**Problem:** Only one generation can run at a time. If a user switches models mid-conversation, the entire Python bridge must restart. The tool execution flow is deeply nested:

```
generateResponse → processStream → toolCalls → executeToolCall → generateResponse (recursive)
```

**Improvement ideas:**
- Support **model hot-swapping** without restarting the bridge — already implemented in Python (`unload_models(keep_registry:)`), but Swift doesn't leverage it when switching between Vision models
- Allow **concurrent tool execution** — web search + image generation could run in parallel if tool calls are independent
- Flatten the recursive `generateResponse` call into an iteration with a tool-call queue

---

## Priority Ranking (Impact × Effort)

| # | Improvement | Impact | Effort | Priority |
|---|------------|--------|--------|----------|
| 1 | ~~Debounce conversation persistence~~ | High | Low | **Done** |
| 2 | Delete dead code (ChatInputView, dup selectors, stray files) | Medium | Low | **Do next** |
| 3 | Generic `executeMediaToolCall` to dedup 3 tool methods | High | Medium | High |
| 4 | Extract ChatStore + services from ChatViewModel | High | Medium | High |
| 5 | Sanitize Python error messages | Medium | Low | High |
| 6 | Enable thinking mode for Qwen | Medium | Low | High |
| 7 | Add request IDs to bridge protocol | Medium | Medium | Medium |
| 8 | Data-driven model registry | High | Medium | Medium |
| 9 | Image caching for message bubbles | Medium | Medium | Medium |
| 10 | Chat rename, regenerate, export | Medium | Medium | Medium |
| 11 | Flatten recursive tool execution into queue | Medium | High | Low |
| 12 | User-adjustable generation parameters | Medium | Low | Medium |
