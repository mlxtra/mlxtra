import Foundation

@MainActor
extension ChatViewModel {
    var hasApprovedMusicLyrics: Bool {
        musicLyricsApproved && !musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasMusicDraftPrompt: Bool {
        !musicPromptForCurrentDraft().isEmpty
    }

    var selectedMusicModelSupportsLyrics: Bool {
        profile(for: .music).supportsMusicLyrics
    }

    var musicComposerPrompt: MusicComposerPrompt? {
        musicComposerResolution().promptState
    }

    var composerDraft: ComposerDraft {
        let musicResolution = musicComposerResolution()
        return ComposerDraftResolver.resolve(
            ComposerDraftContext(
                selectedTool: selectedTool,
                promptIsEmpty: inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                hasSelectedImages: hasSelectedImages,
                selectedImageCount: selectedImagePaths.count,
                isInputDisabled: isInputDisabled,
                isDraftingMusicLyrics: isDraftingMusicLyrics,
                musicLyricsText: musicLyricsText,
                musicPromptState: musicResolution.promptState,
                canCreateMusic: musicResolution.generationDraft != nil
            )
        )
    }

    var composerPlaceholder: String {
        composerDraft.placeholder
    }

    var shouldShowMusicComposerControls: Bool {
        composerDraft.showsMusicControls
    }

    var composerPrimaryActionTitle: String? {
        composerDraft.primaryTitle
    }

    var composerPrimaryActionSystemImage: String {
        composerDraft.primarySystemImage
    }

    var composerPrimaryActionHelp: String {
        composerDraft.primaryHelp
    }

    var composerPrimaryActionDisabledHelp: String {
        composerDraft.disabledHelp
    }

    var isComposerPrimaryActionEnabled: Bool {
        composerDraft.isPrimaryEnabled
    }

    func performComposerPrimaryAction() {
        let draft = composerDraft
        guard draft.isPrimaryEnabled else { return }

        switch draft.primaryAction {
        case .createSong, .send:
            sendMessage()
        }
    }

    @discardableResult
    func submitQuickPrompt(_ prompt: String) -> Bool {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, !isInputDisabled else { return false }

        createNewChat()
        selectedTool = .auto
        selectedImagePaths = []
        isToolMenuOpen = false
        isModelMenuOpen = false
        activeMusicGenerationDraft = nil
        musicVocalMode = .auto
        musicLyricsText = ""
        musicLyricsApproved = false
        isMusicLyricsEditorVisible = false
        musicIntentState = .needsInstrumentalOrVocals
        inputText = trimmedPrompt
        sendMessage()
        return true
    }

    func performComposerSlotAction(_ action: ComposerDraftSlotAction) {
        switch action {
        case .attachReference:
            break
        case .chooseInstrumental:
            selectMusicVocalMode(.instrumental)
        case .chooseVocals:
            selectMusicVocalMode(.vocals)
        case .showLyricsEditor:
            showMusicLyricsEditor()
        case .regenerateLyrics:
            rewriteMusicLyrics()
        }
    }

    @discardableResult
    func prepareMusicGenerationIfNeeded(prompt: String) -> Bool {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return true }
        activeMusicGenerationDraft = nil

        let resolution = musicComposerResolution(prompt: trimmedPrompt)
        if let generationDraft = resolution.generationDraft {
            activeMusicGenerationDraft = generationDraft
            if generationDraft.vocalMode == .instrumental {
                isMusicLyricsEditorVisible = false
                musicLyricsApproved = false
            }
            return true
        }

        if resolution.promptState == .needsLyrics {
            isMusicLyricsEditorVisible = true
        }
        return false
    }

    func selectMusicVocalMode(_ mode: MusicVocalMode) {
        guard selectedMusicModelSupportsLyrics || mode == .instrumental else {
            return
        }
        musicVocalMode = mode
        switch mode {
        case .auto:
            isMusicLyricsEditorVisible = !musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .instrumental:
            musicLyricsApproved = false
            isMusicLyricsEditorVisible = false
        case .vocals:
            isMusicLyricsEditorVisible = hasMusicDraftPrompt || !musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func showMusicLyricsEditor() {
        guard selectedMusicModelSupportsLyrics else { return }
        musicVocalMode = .vocals
        isMusicLyricsEditorVisible = true
    }

    func approveMusicLyrics() {
        guard selectedMusicModelSupportsLyrics else { return }
        guard !musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isMusicLyricsEditorVisible = true
            return
        }
        musicVocalMode = .vocals
        musicLyricsApproved = true
        isMusicLyricsEditorVisible = false
    }

    func rewriteMusicLyrics() {
        musicLyricsApproved = false
        draftMusicLyrics()
    }

    func draftMusicLyrics() {
        let brief = musicPromptForCurrentDraft()
        guard selectedTool == .music,
              selectedMusicModelSupportsLyrics,
              !brief.isEmpty,
              !isInputDisabled,
              !isDraftingMusicLyrics else {
            return
        }

        musicVocalMode = .vocals
        isMusicLyricsEditorVisible = true
        musicLyricsApproved = false

        let draftToken = UUID()
        lyricsDraftToken = draftToken
        lyricsDraftTask?.cancel()
        lyricsDraftTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.cancelLaunchModelPreloadForForegroundUse()
            guard self.ownsActiveLyricsDraft(draftToken) else { return }
            await self.generateMusicLyricsDraft(for: brief, draftToken: draftToken)
        }
    }

    func cancelMusicLyricsDraft() {
        lyricsDraftTask?.cancel()
        lyricsDraftTask = nil
        lyricsDraftToken = nil
        isDraftingMusicLyrics = false
        loadingMessage = ""
    }

    func musicComposerResolution(prompt overridePrompt: String? = nil) -> MusicComposerResolution {
        let prompt = (overridePrompt ?? musicPromptForCurrentDraft()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedTool == .music, !prompt.isEmpty else {
            return MusicComposerResolution(
                prompt: prompt,
                resolvedMode: .auto,
                promptState: nil,
                generationDraft: nil
            )
        }

        let mode = resolvedMusicVocalMode(for: prompt)
        switch mode {
        case .instrumental:
            return MusicComposerResolution(
                prompt: prompt,
                resolvedMode: .instrumental,
                promptState: nil,
                generationDraft: MusicGenerationDraft(vocalMode: .instrumental, lyrics: "[Instrumental]")
            )
        case .vocals:
            return vocalMusicResolution(prompt: prompt)
        case .auto:
            let lyrics = musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !lyrics.isEmpty {
                return lyricsResolution(prompt: prompt, lyrics: lyrics)
            }
            return MusicComposerResolution(
                prompt: prompt,
                resolvedMode: .auto,
                promptState: nil,
                generationDraft: MusicGenerationDraft(vocalMode: .instrumental, lyrics: "[Instrumental]")
            )
        }
    }

    private func vocalMusicResolution(prompt: String) -> MusicComposerResolution {
        let approvedLyrics = musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let embeddedLyrics = lyricsFromPrompt(prompt)
        if !approvedLyrics.isEmpty {
            return lyricsResolution(prompt: prompt, lyrics: approvedLyrics)
        }
        if let embeddedLyrics {
            return MusicComposerResolution(
                prompt: prompt,
                resolvedMode: .vocals,
                promptState: nil,
                generationDraft: MusicGenerationDraft(vocalMode: .vocals, lyrics: embeddedLyrics)
            )
        }
        return MusicComposerResolution(
            prompt: prompt,
            resolvedMode: .vocals,
            promptState: .needsLyrics,
            generationDraft: nil
        )
    }

    private func lyricsResolution(prompt: String, lyrics: String) -> MusicComposerResolution {
        MusicComposerResolution(
            prompt: prompt,
            resolvedMode: .vocals,
            promptState: nil,
            generationDraft: MusicGenerationDraft(vocalMode: .vocals, lyrics: lyrics)
        )
    }

    func resolvedMusicVocalMode(for prompt: String) -> MusicVocalMode {
        if !selectedMusicModelSupportsLyrics {
            return .instrumental
        }

        if let activeMusicGenerationDraft {
            return activeMusicGenerationDraft.vocalMode
        }

        if musicVocalMode != .auto {
            return musicVocalMode
        }

        if promptSoundsInstrumental(prompt) {
            return .instrumental
        }
        if promptSoundsVocal(prompt) || promptContainsLyrics(prompt) {
            return .vocals
        }
        return .auto
    }

    private func musicPromptForCurrentDraft() -> String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func promptSoundsInstrumental(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        return [
            "instrumental",
            "no vocals",
            "without vocals",
            "beat",
            "backing track",
            "background music"
        ].contains { normalized.contains($0) }
    }

    func promptSoundsVocal(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        return [
            "lyrics",
            "vocal",
            "vocals",
            "sing",
            "sung"
        ].contains { normalized.contains($0) }
    }

    func promptContainsLyrics(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        return ["[verse]", "[chorus]", "[bridge]", "lyrics:"].contains { normalized.contains($0) }
    }

    private func lyricsFromPrompt(_ prompt: String) -> String? {
        guard promptContainsLyrics(prompt) else { return nil }
        let markers = ["[verse]", "[chorus]", "[bridge]", "lyrics:"]
        let lowercasedPrompt = prompt.lowercased()
        guard let firstMarker = markers
            .compactMap({ marker -> String.Index? in lowercasedPrompt.range(of: marker)?.lowerBound })
            .min() else {
            return nil
        }

        let lyrics = String(prompt[firstMarker...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return lyrics.isEmpty ? nil : lyrics
    }

    private func ownsActiveLyricsDraft(_ draftToken: UUID) -> Bool {
        lyricsDraftToken == draftToken
    }

    private func generateMusicLyricsDraft(for brief: String, draftToken: UUID) async {
        guard ownsActiveLyricsDraft(draftToken) else { return }
        isDraftingMusicLyrics = true
        loadingMessage = "Generating lyrics..."

        defer {
            if ownsActiveLyricsDraft(draftToken) {
                isDraftingMusicLyrics = false
                lyricsDraftTask = nil
                lyricsDraftToken = nil
                if !isGenerating && !isModelLoading && !isPythonLoading {
                    loadingMessage = ""
                }
            }
        }

        do {
            let chatProfile = profile(for: .chat)
            guard await requireDownloadedModel(model: chatProfile.downloadableModel, operation: "Lyrics writing") else {
                return
            }
            guard ownsActiveLyricsDraft(draftToken) else { return }

            setActiveEngineModel(name: chatProfile.name, role: .chat)

            guard try await ensureLocalRuntimeReady() else { return }
            guard ownsActiveLyricsDraft(draftToken) else { return }

            loadingMessage = "Generating lyrics..."
            let baseChatExecutionParameters = modelParameterStore.executionParameters(for: chatProfile)
            let chatExecutionParameters = chatProfile.executionParameters(merging: baseChatExecutionParameters)
            let chatTemplateKwargs = chatProfile.runtimeOptions?.chatTemplateKwargs(from: chatExecutionParameters)
            let runtimeOptions = chatProfile.runtimeExecutionOptions()
            let requestParameters = runtimeOptions.isEmpty ? nil : ["runtimeOptions": runtimeOptions]
            let request = ExecutionRequest(
                backend: .vlm,
                modelId: chatProfile.modelId,
                messages: [
                    ExecutionMessage(
                        role: .system,
                        content: "Write song lyrics only. Use short section labels like [verse] and [chorus]. Do not include explanation, markdown fences, or production notes."
                    ),
                    ExecutionMessage(
                        role: .user,
                        content: "Song idea: \(brief)\n\nWrite concise, singable lyrics for this song."
                    )
                ],
                maxTokens: min((chatExecutionParameters["max_tokens"] as? Int) ?? chatProfile.defaultMaxTokens, 900),
                temperature: max((chatExecutionParameters["temperature"] as? Double) ?? 0.8, 0.7),
                topP: chatExecutionParameters["top_p"] as? Double ?? chatProfile.doubleParameterDefault("top_p", fallback: 1.0),
                topK: chatExecutionParameters["top_k"] as? Int ?? chatProfile.intParameterDefault("top_k", fallback: 0),
                minP: chatExecutionParameters["min_p"] as? Double ?? chatProfile.doubleParameterDefault("min_p", fallback: 0),
                repetitionPenalty: chatExecutionParameters["repetition_penalty"] as? Double ?? chatProfile.doubleParameterDefault("repetition_penalty", fallback: 1.0),
                chatTemplateKwargs: chatTemplateKwargs,
                tools: nil,
                parameters: requestParameters
            )

            let stream = try await vlmExecutor.execute(request: request)
            guard ownsActiveLyricsDraft(draftToken) else { return }
            var draft = ""
            var didComplete = false
            for await event in stream {
                if Task.isCancelled || !ownsActiveLyricsDraft(draftToken) { return }

                switch event {
                case .token(let token):
                    draft += token
                case .complete(let response, _):
                    didComplete = true
                    draft = response
                case .progress(let message):
                    loadingMessage = message
                case .modelLoadProgress(let progress):
                    loadingMessage = progress.detail ?? progress.phase.displayTitle
                case .generationProgress(let progress):
                    loadingMessage = progress.displayDetail
                case .error(let error):
                    throw error
                case .started, .image, .audio, .toolCalls:
                    break
                }
            }

            guard ownsActiveLyricsDraft(draftToken) else { return }
            let cleanedDraft = cleanLyricsDraft(draft)
            guard didComplete else {
                if !cleanedDraft.isEmpty {
                    musicLyricsText = cleanedDraft
                    musicLyricsApproved = false
                }
                isMusicLyricsEditorVisible = true
                throw ExecutionError.processStopped("Lyrics draft stream ended before reporting completion.")
            }

            if !cleanedDraft.isEmpty {
                musicLyricsText = cleanedDraft
                musicLyricsApproved = false
                isMusicLyricsEditorVisible = true
            } else {
                isMusicLyricsEditorVisible = true
            }
        } catch {
            if Task.isCancelled || !ownsActiveLyricsDraft(draftToken) { return }
            isMusicLyricsEditorVisible = true
            localEngineErrorMessage = lyricsDraftErrorMessage(for: error)
        }
    }

    private func lyricsDraftErrorMessage(for error: Error) -> String {
        guard let executionError = error as? ExecutionError else {
            return "Could not generate lyrics. Paste lyrics or try again."
        }

        switch executionError {
        case .processCrashed, .processNotRunning, .processStopped, .pipeWriteFailed, .timeout:
            return "The local engine stopped before lyrics finished. Restart to continue."
        case .pythonError(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Could not generate lyrics. Paste lyrics or try again."
                : "Could not generate lyrics: \(trimmed)"
        default:
            return "Could not generate lyrics. Paste lyrics or try again."
        }
    }

    private func cleanLyricsDraft(_ draft: String) -> String {
        draft
            .replacingOccurrences(of: "```lyrics", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
