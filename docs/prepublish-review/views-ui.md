# MLXtra Views and UI Tests Pre-Publish Review

## Scope

- Reviewed every code file under `MLXtra/Views`, `MLXtra/Views/Components`, and `MLXtraUITests`.
- Scope was read-only for code. This file is the only edited artifact.
- Files reviewed: 27 total, covering 24 view/component files and 3 UI test files.

## Counts By Severity

- P0: 0
- P1: 1
- P2: 8
- P3: 4
- Low-confidence notes: 3
- Total findings: 13

## P0

No P0 findings.

## P1

### P1-1: Image lightbox save silently deletes the destination before verifying the copy succeeds

- File: `MLXtra/Views/MessageGeneratedImageAttachmentView.swift:354`
- Confidence: high
- Why it matters: The lightbox download path removes any existing file at the chosen destination and then suppresses both remove/copy errors with `try?` at lines 361-362. If the source image is unavailable, the destination is read-only, disk is full, or the copy fails after deletion, the user can lose an existing file with no alert. The non-lightbox image card path handles errors; this path does not.
- Concrete fix: Reuse the checked `downloadImage` implementation from the card, or extract a shared `copyGeneratedFile(to:) throws` helper. Do not remove the destination until the replacement can be completed safely; prefer `FileManager.replaceItemAt` or copy to a temporary sibling then atomically replace, and surface failures through the same alert state.

## P2

### P2-1: Copied feedback task can update view state after the message row is gone

- File: `MLXtra/Views/MessageBubbleView.swift:329`
- Confidence: high
- Why it matters: `copyToClipboard()` starts an unstructured `Task` that sleeps for two seconds, then writes `showCopyFeedback = false`. Unlike `cursorAnimationTask`, this task is not stored or cancelled in `onDisappear`. Deleting/switching chats or list recycling can leave a task targeting stale SwiftUI state, causing confusing feedback changes or runtime warnings during publish builds.
- Concrete fix: Store the copy-feedback task in `@State`, cancel it before starting a new one, and cancel it in `onDisappear`. Alternatively drive the reset with `.task(id: showCopyFeedback)` tied to the view lifecycle.

### P2-2: NSSound fallback playback never updates progress or completion state

- File: `MLXtra/Views/MessageGeneratedAudioAttachmentView.swift:173`
- Confidence: high
- Why it matters: If `AVAudioPlayer` initialization fails and the view falls back to `NSSound`, `startPlayback()` sets `isPlaying` but does not call `startTimer()`, and the timer loop only handles `AVAudioPlayer`. The play button can stay in pause state after playback ends, the scrubber/time labels remain stale, and seeking cannot work for fallback formats.
- Concrete fix: Prefer one playback backend. If `NSSound` remains as fallback, add an `NSSoundDelegate` or polling path that updates `currentTime`, resets `isPlaying` on completion, and handles seeking limitations explicitly.

### P2-3: Download save panels constrain generated audio and images to fixed extensions

- File: `MLXtra/Views/MessageGeneratedAudioAttachmentView.swift:244`
- Confidence: high
- Why it matters: `downloadAudio()` always sets `allowedContentTypes = [.wav]`, while generated music/speech paths may evolve to other audio formats. `GeneratedImageAttachmentView` similarly forces `.png` at line 190. The UI names the destination with `lastPathComponent`, so a future `.mp3`, `.m4a`, `.jpg`, or `.webp` output could be saved through a mismatched panel/type policy or be blocked unexpectedly.
- Concrete fix: Derive the allowed content type from `audioURL`/`imageURL.resourceValues(.contentTypeKey)` and fall back to a sensible type only when unknown. Keep the original extension as the default save name.

### P2-4: Composer input exposes the same accessibility identifier on both scroll view and text view

- File: `MLXtra/Views/ComposerInputViews.swift:57`
- Confidence: high
- Why it matters: `MultilineTextInput` sets `composer.input` on both the enclosing `NSScrollView` and the inner `NSTextView` at lines 57 and 66. The tests already have to fall back between `app.textViews["composer.input"]` and `app.descendants["composer.input"]`, which is a symptom of an ambiguous accessibility tree. VoiceOver and UI automation can target the wrong element, especially when there are multiple composer-like fields.
- Concrete fix: Give the scroll view and text view distinct identifiers, for example `composer.inputScrollView` and `composer.inputTextView`, and update UI tests to target the editable text view. Keep the user-facing accessibility label only on the editable control.

### P2-5: First-run guide can overflow the welcome rail at narrower window widths

- File: `MLXtra/Views/WelcomeView.swift:275`
- Confidence: medium
- Why it matters: `FirstRunGuideView` is a single `HStack` containing copy plus three trailing buttons, and it is capped to the message rail by the parent. There is no wrapping, layout priority, or adaptive split for the actions. At narrow-but-supported macOS window widths or with longer localized strings/model names, buttons can compress text, overlap, or push off the rail.
- Concrete fix: Make the guide adaptive: move actions into a wrapping `ViewThatFits`, vertical stack, or compact menu below a width threshold. Add a UI test width case with the first-run guide visible.

### P2-6: Settings window is hard-coded to 900 x 680 with no adaptive fallback

- File: `MLXtra/Views/SettingsView.swift:62`
- Confidence: high
- Why it matters: The settings root uses a fixed frame while the header contains badges and a refresh button, and rows reserve fixed action widths. On smaller displays, Stage Manager, external low-resolution screens, or accessibility display scaling, the window can be too large or content can clip instead of adapting.
- Concrete fix: Use `frame(minWidth:idealWidth:maxWidth:minHeight:idealHeight:maxHeight:)` plus internal responsive wrapping for header controls. Add a settings UI test for a constrained window size.

### P2-7: Pending model reveal can scroll before the row exists after switching model mode

- File: `MLXtra/Views/SettingsView.swift:57`
- Confidence: medium
- Why it matters: `revealPendingModelIfNeeded` sets `selectedModelMode` and immediately calls `scrollToPendingModel`, which only defers one main queue turn. The row list changes as a result of the mode switch, so the target `.id(model.modelId)` may not exist when the scroll executes, especially after async catalog refresh or search/filter changes. Users opening settings from a missing-model callout may not be taken to the required model.
- Concrete fix: Trigger the scroll from `.onChange(of: selectedModelMode)` or after the filtered list contains the pending model, and retry once after layout. Clear search/filter or account for them before scrolling.

### P2-8: Destructive chat delete has no confirmation or undo path

- File: `MLXtra/Views/SidebarView.swift:60`
- Confidence: medium
- Why it matters: Both the row context menu and hover menu call `viewModel.deleteChat(chat)` directly. A mis-click in a dense sidebar can remove a conversation immediately. For pre-publish readiness, destructive user data actions should be reversible or confirmed.
- Concrete fix: Add a confirmation dialog for delete, or implement undo via `UndoManager`/recently deleted state. Keep keyboard and context-menu paths routed through the same confirmation/undo flow.

## P3

### P3-1: Welcome chip accessibility identifiers do not match visible titles

- File: `MLXtra/Views/WelcomeView.swift:115`
- Confidence: high
- Why it matters: Production code generates identifiers such as `welcome.tool.ask`, while UI tests select `welcome.tool.Chat`/`Image`/`Speech` using fixture aliases. That mismatch makes tests depend on hidden UI-test behavior elsewhere and makes identifiers less predictable for future automation.
- Concrete fix: Base identifiers on stable tool IDs instead of display titles, for example `welcome.tool.chat`, `welcome.tool.image`, `welcome.tool.tts`, and update tests to use the same identifiers the app ships.

### P3-2: Model settings test is coupled to a specific catalog model name

- File: `MLXtraUITests/MLXtraChatLayoutUITests.swift:737`
- Confidence: high
- Why it matters: `assertSettingsModelLayoutIsAligned()` waits for `app.staticTexts["Gemma 4"]`. A catalog rename, recommendation change, or localization update will fail the layout test even when the UI is correct. This is brittle for pre-publish cleanup where model catalog content is likely to change.
- Concrete fix: Query the first `settings.modelRow.*` element or a known fixture identifier under `MLXTRA_UI_TEST_DOWNLOAD_STATES`, then assert layout against row subelements rather than a hard-coded marketing name.

### P3-3: Download-state UI test assertions are broad enough to pass on the wrong pane

- File: `MLXtraUITests/MLXtraDownloadStatesUITests.swift:51`
- Confidence: medium
- Why it matters: Assertions like `app.staticTexts["Ready"].exists` and `app.buttons["Download"].exists` are global. A stale popover, sidebar text, or another pane element can satisfy them, so regressions in the specific model rows may be missed.
- Concrete fix: Scope assertions to `settings.modelList` descendants or row identifiers for each expected state. Prefer `settings.modelState.ready/missing/downloading/paused/repair/failed` identifiers over visible strings.

### P3-4: UI tests repeat launch fixture routing by test-name substring

- File: `MLXtraUITests/MLXtraChatLayoutUITests.swift:36`
- Confidence: medium
- Why it matters: `setUpWithError()` infers window size and fixture flags from `name.contains(...)`. Renaming a test silently changes its environment. This makes UI coverage fragile and hard to extend.
- Concrete fix: Move fixture configuration into explicit per-test helpers, for example `launch(window:fixture:)`, and call it from each test before `app.launch()`.

## Low-Confidence Notes

### LC-1: Streaming text height throttling may clip fast-growing content under heavy token bursts

- File: `MLXtra/Views/MessageAIContentView.swift:427`
- Confidence: low
- Why it matters: `refreshMeasuredHeight` throttles height measurement to 30-60 Hz while `StreamingAIContentView` clips the native text view. If a large chunk arrives between measurements, the view may briefly clip bottom lines until the next forced measurement. This may be acceptable, but it is worth stress-testing with large streamed chunks.
- Concrete fix: Add a UI/runtime probe that streams large newline-heavy chunks and checks the native text view remains fully visible. If clipping appears, force height refresh when appended chunks contain newlines or exceed a size threshold.

### LC-2: Global local scroll monitor may disable autoscroll from nested scroll interactions

- File: `MLXtra/Views/ChatView.swift:266`
- Confidence: low
- Why it matters: `TranscriptScrollIntentObserver` installs a local `.scrollWheel` monitor and checks whether the event lands inside the transcript scroll view. Horizontal scrolls inside code blocks/tables could be interpreted as user transcript scrolling and disable autoscroll while a response streams.
- Concrete fix: Ignore predominantly horizontal wheel events, or require the transcript document bounds to change before marking `isUserScrolling`.

### LC-3: Attachment removal by captured index can remove the wrong thumbnail if the array mutates

- File: `MLXtra/Views/ComposerView.swift:91`
- Confidence: low
- Why it matters: The attachment tray iterates over indices and captures `index` for removal. If async drop/paste completion appends or deduplicates images while the tray is being interacted with, a stale index could remove a different item.
- Concrete fix: Remove by stable URL/path instead of index, or bind each thumbnail to an identifiable attachment model.
