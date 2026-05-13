# MLXtra Services/ViewModels Pre-Publish Review

## Scope

Reviewed every Swift code file under `MLXtra/ViewModels` and `MLXtra/Services`:

- `MLXtra/ViewModels`: 11 files
- `MLXtra/Services`: 6 files
- Total reviewed files: 17

Review focus: bugs, crashes, data loss, concurrency, task lifecycle, publish-readiness, dead code, large-method/file split needs, duplicated logic, confusing APIs, and test gaps.

## Counts by Severity

- P0: 0
- P1: 4
- P2: 7
- P3: 5
- Low-confidence notes: 3
- Total findings: 16

## P0

No P0 findings.

## P1

### P1: Cancellation can leave generation stuck in disabled state

- File: `MLXtra/ViewModels/ChatViewModel.swift:743`
- Confidence: high
- Why it matters: `generateResponse` returns immediately when `Task.isCancelled` is true, without calling `finishActiveGeneration`, clearing `streamingMessageId`, or marking the in-progress assistant message stopped. `cancelGeneration()` clears state for direct user cancellation, but the same cancellation path can be reached from nested tool/generation flows or parent task cancellation. A stuck `generationTask`/streaming state disables input and can leave an unfinished message in memory or persistence.
- Concrete fix: In the catch cancellation branch, call a shared cancellation cleanup helper that marks the active message stopped, clears `isGenerating`, `isModelLoading`, `streamingMessageId`, `generationTask`, `loadingMessage`, and flushes/schedules persistence. Add a test with a cancellable mock executor that throws `CancellationError` before stream completion.

### P1: Runtime validation blocks the MainActor synchronously

- File: `MLXtra/Services/Runtime/RuntimeManager.swift:584`
- Confidence: high
- Why it matters: `validateDownloadSupport(for:)` is `@MainActor` and calls `validatePythonImports`, which starts Python, calls `process.waitUntilExit()`, and then `group.wait()` synchronously. Downloads call this from `ModelDownloadManager.download()` on the main actor before the async helper run. If the validation import hangs or is slow, the app UI freezes, which is a publish-readiness issue.
- Concrete fix: Make import validation async and run it off the main actor using an async process runner with a timeout, or move all validation work into `Task.detached` and return to the main actor only to update state. Add a timeout test for a helper process that never exits.

### P1: Runtime archive install is vulnerable to unsafe zip paths

- File: `MLXtra/Services/Runtime/RuntimeManager.swift:428`
- Confidence: medium
- Why it matters: Runtime updates are downloaded over the network and extracted with `/usr/bin/ditto -x -k` into a staging directory, but there is no explicit path traversal/symlink validation before trusting `normalizedRuntimeRoot` and moving it into Application Support. A malicious or compromised channel asset could attempt to write outside staging or smuggle unsafe symlinks/executables into the installed runtime.
- Concrete fix: Before install, enumerate archive entries with a safe zip library or `ditto`/`zipinfo` equivalent and reject absolute paths, `..` components, and symlinks that resolve outside the extracted runtime root. After extraction, walk the runtime root with `resolvingSymlinksInPath()` and reject any entry escaping the root. Add tests using crafted archives.

### P1: MCP web search ships with a hard-coded third-party endpoint and no opt-in/auth handling

- File: `MLXtra/Services/MCP/MCPWebSearchService.swift:50`
- Confidence: high
- Why it matters: The default service sends user search queries to `https://mcp.exa.ai/mcp`. For a pre-publish app, this is a privacy and reliability risk: users may not expect prompts/searches to leave the device, the endpoint may require credentials or change behavior, and failures become part of normal chat/tool flow.
- Concrete fix: Make web search explicitly opt-in via settings, document the provider, require configured credentials/session state if needed, and make the default server list empty until enabled. Add tests that no network search is attempted when the feature is disabled.

## P2

### P2: Chat persistence can lose final debounced writes on normal app exit

- File: `MLXtra/ViewModels/ChatServices.swift:191`
- Confidence: medium
- Why it matters: `scheduleSave` debounces final message persistence by one second. `flushPendingSave()` is called on cancellation and before loads, but there is no obvious app-lifecycle flush in this slice. If the app quits shortly after a generation completes, the last assistant response or selected chat can be lost.
- Concrete fix: Flush pending saves from the app scene phase/application termination path, or make `scheduleSave` write immediately for terminal generation events while keeping debounce for streaming updates. Add a persistence test that schedules a save and simulates shutdown before the debounce fires.

### P2: `saveChats` and `scheduleSave` can race and write older snapshots after newer ones

- File: `MLXtra/ViewModels/ChatServices.swift:169`
- Confidence: medium
- Why it matters: Immediate saves enqueue async writes on `writeQueue`, while debounced saves enqueue a later `DispatchWorkItem`. There is no monotonic revision check when writing. A delayed stale snapshot can run after a newer immediate save and overwrite newer conversations.
- Concrete fix: Add a persistence revision counter captured with each snapshot and skip writes older than the latest accepted revision, or funnel all saves through one coalescing path. Add ordering tests with immediate save followed by scheduled stale save.

### P2: Attachment fallback stores external file URLs that may become invalid

- File: `MLXtra/ViewModels/ChatServices.swift:312`
- Confidence: high
- Why it matters: If copying an attachment fails, `persistAttachments` returns the original source URL. That URL may point to a temporary picker location or a file outside app ownership, so restored chats can show broken attachments later and may expose paths the app should not depend on.
- Concrete fix: Treat copy failure as a failed attachment import: omit that attachment and surface a user-facing import error, or keep a security-scoped bookmark if external references are intentional. Add a test where `copyItem` fails and verify persisted messages do not retain temporary source paths.

### P2: Download helper continuation can resume after a failed `process.run()`

- File: `MLXtra/Services/Runtime/DownloadHelperProcessRunner.swift:100`
- Confidence: medium
- Why it matters: The termination handler is installed before `process.run()`. If `run()` throws after partially launching or a termination callback still fires, the checked continuation can be resumed both in the catch block and termination handler, causing a runtime trap. This is rare but painful in publish builds.
- Concrete fix: Wrap continuation completion in a small lock-protected `resumeOnce` helper and clear pipe handlers on launch failure. Add a unit test with an invalid executable and, if possible, a process that exits immediately.

### P2: Model download cancellation does not reliably cancel the helper runner

- File: `MLXtra/Services/Runtime/ModelDownloadManager.swift:453`
- Confidence: medium
- Why it matters: `stop()` cancels the task and terminates the tracked process if present, but `DownloadHelperProcessRunner.run` itself is not cancellation-aware. If cancellation happens before `onProcessStarted` records the process, or if termination races with startup, the task can remain awaiting the checked continuation until the helper exits naturally.
- Concrete fix: Use `withTaskCancellationHandler` inside `runDownloadHelper`/`DownloadHelperProcessRunner.run` to terminate the process as soon as the parent task is cancelled, even before `onProcessStarted` returns. Add tests for pause/cancel immediately after starting a download.

### P2: Direct media tool execution does not initialize the executor

- File: `MLXtra/ViewModels/ChatServices.swift:377`
- Confidence: medium
- Why it matters: `DefaultChatToolExecutionService.executeMediaTool` calls `modelExecutor.execute(request:)` directly. This works only if the outer chat flow already initialized the executor. The service API itself has no precondition or initialization step, so future callers/tests that execute a media tool directly can fail with `.notInitialized`.
- Concrete fix: Either call `try await modelExecutor.initialize()` before `execute`, or make `ChatToolExecutionServicing` explicitly require a ready executor and assert/test that contract. Prefer initializing defensively because the service already owns runtime/model execution orchestration.

### P2: Large `ChatViewModel` extension surface hides lifecycle ownership

- File: `MLXtra/ViewModels/ChatViewModel.swift:22`
- Confidence: high
- Why it matters: Generation state, model selection, download prompts, tool execution, music drafting, persistence, and local engine status are spread across many same-type extensions with shared mutable properties. This makes task lifecycle bugs harder to reason about and increases regression risk during pre-publish cleanup.
- Concrete fix: Split ownership by behavior rather than only extension files: move persistence orchestration, local engine lifecycle, and media/tool execution into small collaborating `@MainActor` controllers/services with narrow protocols. Start with generation lifecycle cleanup because it already spans `ChatViewModel.swift`, `+Streaming`, `+Messages`, `+Models`, and `ChatServices`.

## P3

### P3: Dead no-op `loadModel(_:)` is misleading

- File: `MLXtra/ViewModels/ChatViewModel+Streaming.swift:5`
- Confidence: high
- Why it matters: `generateResponse` sets loading UI and calls `try await loadModel(resolvedModelId)`, but the method intentionally does nothing because `VLMExecutor.execute` performs lazy loading. This makes the code read as if model loading happened before the assistant message is created, while it actually happens later inside `execute`.
- Concrete fix: Remove the method and the call, or rename it to something explicit like `prepareModelLoadUI` if the intent is UI-only. Keep lazy loading in `VLMExecutor` and test model-loading progress through the stream/delegate path.

### P3: Unused runtime states make the lifecycle API confusing

- File: `MLXtra/Services/Runtime/RuntimeManager.swift:270`
- Confidence: high
- Why it matters: `RuntimeState.extractingBundle` and `.startingPython` are defined and displayed by `LocalEngineStatus`, but `initialize()` never sets them. This makes status handling look more complete than it is and can mislead future UI/tests.
- Concrete fix: Remove unused states or set them in the actual extraction/startup paths. Add state-transition tests for `RuntimeManager.initialize()`.

### P3: Unused helper increases maintenance noise

- File: `MLXtra/Services/Runtime/ModelDownloadManager.swift:519`
- Confidence: high
- Why it matters: `isModelDownloadedOffMain(modelId:)` is private and unused in `ModelDownloadManager`; there is another similarly named implementation in `ChatViewModel+Models.swift` and `ChatServices.swift`. The duplication makes it harder to know which path is authoritative.
- Concrete fix: Delete the unused private method or route all download status checks through one shared helper.

### P3: Duplicated bundled Python environment construction can drift

- File: `MLXtra/Services/Execution/VLM/VLMExecutor.swift:197`
- Confidence: high
- Why it matters: `VLMExecutor`, `RuntimeManager`, and `ModelDownloadManager` each build bundled Python environments with overlapping but non-identical variables. For example, executor sets Metal and ACE-Step variables, downloader sets Hugging Face cache variables, and runtime validation sets neither cache nor Metal variables. Future runtime fixes can easily land in one path and miss another.
- Concrete fix: Centralize environment construction in `RuntimeManager` with small option flags for execution, download, validation, and ACE-Step. Add tests that required variables are present for each launch mode.

### P3: Composer model has unused slot action structures

- File: `MLXtra/ViewModels/ChatComposerModels.swift:175`
- Confidence: medium
- Why it matters: `ComposerDraftSlotAction`, `ComposerDraftSlotActionItem`, and `ComposerDraftSlot` are modeled, but `ComposerDraftResolver.resolve` always returns `slots = []`. This reads like an unfinished feature and expands the API surface without current behavior.
- Concrete fix: Either wire slots into the composer UI/resolver or remove the unused slot model until it is needed. Add snapshot/UI tests if slots are reintroduced.

## Low-Confidence Notes

### LC: Tool-call completion may drop a text response when malformed tool calls are emitted

- File: `MLXtra/Services/Execution/VLM/VLMExecutor.swift:665`
- Confidence: low
- Why it matters: `chat.completion.tool_calls` finishes the stream only inside the branch where `tool_call` dictionaries exist. If the bridge emits a malformed/empty tool-call event, the stream may neither finish nor surface an error, depending on subsequent bridge output.
- Concrete fix: Treat malformed tool-call events as `.error(ExecutionError.invalidResponse)` or ignore them without finishing only if the bridge guarantees a later complete/error event. Add bridge contract tests for malformed tool-call payloads.

### LC: Image/audio direct generation may rely on bridge-specific completion behavior

- File: `MLXtra/Services/Execution/VLM/VLMExecutor.swift:689`
- Confidence: low
- Why it matters: `.image` and `.audio` events do not finish the stream; completion depends on a later `chat.completion.complete` or equivalent bridge event. If any media bridge path only emits `image.generated`/`audio.generated`, `processStream` waits until timeout and may convert a successful generation into an error.
- Concrete fix: Document and test the bridge contract for media events, or finish media streams after the asset event when the request backend is `.image`, `.audio`, or `.music` and no additional completion payload is required.

### LC: `MCPHTTPClient` MainActor isolation serializes network parsing with UI work

- File: `MLXtra/Services/MCP/MCPWebSearchService.swift:140`
- Confidence: low
- Why it matters: The HTTP client is `@MainActor`, so response parsing and JSON/SSE handling resume on the main actor. For small responses this is fine, but large search results could cause UI hitches.
- Concrete fix: Make the HTTP client nonisolated or move network parsing into a detached helper, returning only the final search context to the main actor.
