import Foundation

@MainActor
extension ChatViewModel {
    var hasApprovedMusicLyrics: Bool {
        musicLyricsApproved && !musicLyricsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasMusicDraftPrompt: Bool {
        !musicPromptForCurrentDraft().isEmpty
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
        musicVocalMode = .vocals
        isMusicLyricsEditorVisible = true
    }

    func approveMusicLyrics() {
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
              !brief.isEmpty,
              !isInputDisabled,
              !isDraftingMusicLyrics else {
            return
        }

        musicVocalMode = .vocals
        isMusicLyricsEditorVisible = true
        musicLyricsApproved = false

        lyricsDraftTask?.cancel()
        lyricsDraftTask = Task { [weak self] in
            guard let self else { return }
            await self.cancelLaunchModelPreloadForForegroundUse()
            await self.generateMusicLyricsDraft(for: brief)
        }
    }

    func cancelMusicLyricsDraft() {
        lyricsDraftTask?.cancel()
        lyricsDraftTask = nil
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

    private func generateMusicLyricsDraft(for brief: String) async {
        isDraftingMusicLyrics = true
        loadingMessage = "Generating lyrics..."

        defer {
            isDraftingMusicLyrics = false
            lyricsDraftTask = nil
            if !isGenerating && !isModelLoading && !isPythonLoading {
                loadingMessage = ""
            }
        }

        do {
            let chatProfile = profile(for: .chat)
            let chatModel = chatProfile.aiModel ?? selectedModel
            guard await requireDownloadedModel(model: chatProfile.downloadableModel, operation: "Lyrics writing") else {
                return
            }

            setActiveEngineModel(name: chatProfile.name, role: .chat)

            try await ensureLocalRuntimeReady()

            loadingMessage = "Generating lyrics..."
            let chatExecutionParameters = modelParameterStore.executionParameters(for: chatProfile)
            let enableThinking = (chatExecutionParameters["enable_thinking"] as? Bool) ?? false
            let chatTemplateKwargs: [String: Any]? = chatProfile.modelId.lowercased().contains("qwen")
                ? ["enable_thinking": enableThinking]
                : nil
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
                maxTokens: min((chatExecutionParameters["max_tokens"] as? Int) ?? chatModel.defaultMaxTokens, 900),
                temperature: max((chatExecutionParameters["temperature"] as? Double) ?? 0.8, 0.7),
                topP: chatExecutionParameters["top_p"] as? Double ?? chatModel.topP,
                topK: chatExecutionParameters["top_k"] as? Int ?? chatModel.topK,
                minP: chatExecutionParameters["min_p"] as? Double ?? chatModel.minP,
                repetitionPenalty: chatExecutionParameters["repetition_penalty"] as? Double ?? chatModel.repetitionPenalty,
                chatTemplateKwargs: chatTemplateKwargs,
                tools: nil
            )

            let stream = try await vlmExecutor.execute(request: request)
            var draft = ""
            for await event in stream {
                if Task.isCancelled { return }

                switch event {
                case .token(let token):
                    draft += token
                case .complete(let response, _):
                    draft = response
                case .progress(let message):
                    loadingMessage = message
                case .modelLoadProgress(let progress):
                    loadingMessage = progress.detail ?? progress.phase.displayTitle
                case .error(let error):
                    throw error
                case .started, .image, .audio, .toolCalls:
                    break
                }
            }

            let cleanedDraft = cleanLyricsDraft(draft)
            if !cleanedDraft.isEmpty {
                musicLyricsText = cleanedDraft
                musicLyricsApproved = false
                isMusicLyricsEditorVisible = true
            } else {
                isMusicLyricsEditorVisible = true
            }
        } catch {
            if Task.isCancelled { return }
            isMusicLyricsEditorVisible = true
            localEngineErrorMessage = "Could not generate lyrics. Paste lyrics or try again."
        }
    }

    private func cleanLyricsDraft(_ draft: String) -> String {
        draft
            .replacingOccurrences(of: "```lyrics", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
