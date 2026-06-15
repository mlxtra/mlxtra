import Foundation

@MainActor
extension ChatViewModel {
    var localEngineStatus: LocalEngineStatus {
        LocalEngineStatus.resolve(
            runtimeState: runtimeManager.state,
            isPythonLoading: isPythonLoading,
            isModelLoading: isModelLoading,
            isPreloadingLocalModel: isPreloadingLocalModel,
            isGenerating: isGenerating,
            isTerminatingLocalEngine: isTerminatingLocalEngine,
            loadingMessage: loadingMessage,
            loadProgress: modelLoadProgress,
            generationProgress: generationProgress,
            isExecutorReady: vlmExecutor.isReady,
            isModelLoaded: vlmExecutor.isModelLoaded,
            selectedModelName: activeModelProfile.name,
            activeModelName: loadedEngineModelName ?? activeEngineModelName,
            activeModelRole: loadedEngineModelRole ?? activeEngineModelRole,
            pendingDownloadModelId: pendingEngineDownloadModel?.modelId,
            pendingDownloadModelName: pendingEngineDownloadModel?.name,
            pendingDownloadDetail: pendingEngineDownloadDetail,
            freedModelName: freedEngineModelName,
            lastErrorMessage: localEngineErrorMessage
        )
    }

    var canFreeLocalEngineMemory: Bool {
        !isInputDisabled && localEngineStatus.canFreeMemory
    }

    var activeModelProfile: ModelCapabilityProfile {
        profile(for: selectedTool)
    }

    var availableProfilesForCurrentMode: [ModelCapabilityProfile] {
        ModelCapabilityProfile.sortedProfiles(for: modelModality(for: selectedTool))
    }

    func freeLocalEngineMemory() {
        guard canFreeLocalEngineMemory else { return }

        cancelLaunchModelPreload()
        let freedModelName = loadedEngineModelName ?? activeEngineModelName ?? activeModelProfile.name
        isPythonLoading = false
        isModelLoading = false
        isGenerating = false
        loadingMessage = ""
        modelLoadProgress = nil
        generationProgress = nil
        localEngineErrorMessage = nil

        if engineTerminationTask == nil {
            scheduleEngineTermination()
        }
        activeEngineModelName = nil
        activeEngineModelRole = .chat
        self.freedEngineModelName = freedModelName
    }

    func restartLocalEngine() {
        guard !isInputDisabled else { return }

        cancelLaunchModelPreload()
        isPythonLoading = true
        loadingMessage = "Preparing local engine..."
        modelLoadProgress = nil
        generationProgress = nil
        activeEngineModelName = nil
        activeEngineModelRole = .chat
        freedEngineModelName = nil
        localEngineErrorMessage = nil

        Task {
            await vlmExecutor.terminate()

            do {
                try await runtimeManager.initialize()
                try await vlmExecutor.initialize()
                isPythonLoading = false
                loadingMessage = ""
                modelLoadProgress = nil
                generationProgress = nil
            } catch {
                isPythonLoading = false
                loadingMessage = ""
                modelLoadProgress = nil
                generationProgress = nil
                localEngineErrorMessage = "The local engine stopped. Restart to continue."
            }
        }
    }

    func refreshLocalEngineDownloadStatus() {
        let currentPendingModel = pendingEngineDownloadModel
        let currentTool = selectedTool
        let refreshToken = UUID()
        downloadStatusRefreshToken = refreshToken

        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await selectDownloadedDefaultModelIfNeeded(for: modelModality(for: currentTool))
            guard isActiveDownloadStatusRefresh(refreshToken, tool: currentTool) else { return }
            let selectionRequirement = downloadRequirement(for: currentTool)

            if let currentPendingModel,
               await isModelDownloadedOffMain(model: currentPendingModel) {
                guard isActiveDownloadStatusRefresh(refreshToken, tool: currentTool) else { return }
                if pendingEngineDownloadModel?.modelId == currentPendingModel.modelId {
                    clearPendingEngineDownloadModel(matching: currentPendingModel.modelId)
                }
            }

            guard isActiveDownloadStatusRefresh(refreshToken, tool: currentTool) else { return }
            await refreshSelectedDownloadRequirement(
                selectionRequirement,
                refreshToken: refreshToken,
                tool: currentTool
            )
        }
    }

    func scheduleLaunchModelPreload(
        delayNanoseconds: UInt64 = ChatViewModel.defaultLaunchModelPreloadDelayNanoseconds
    ) {
        let profile = profile(for: .chat)
        guard launchModelPreloadTask == nil,
              !isPreloadingLocalModel,
              !isLoadedEngineModel(modelId: profile.modelId, backend: profile.backend),
              isLaunchModelPreloadEnabled else {
            return
        }

        launchModelPreloadTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                if delayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                }
                try Task.checkCancellation()
                await self.preloadSelectedLaunchModelIfEligible()
            } catch is CancellationError {
                self.finishLaunchModelPreload()
            } catch {
                self.finishLaunchModelPreload()
            }
        }
    }

    func cancelLaunchModelPreload() {
        guard launchModelPreloadTask != nil || isPreloadingLocalModel else { return }

        launchModelPreloadTask?.cancel()
        launchModelPreloadTask = nil
        let shouldTerminateEngine = isPreloadingLocalModel
        finishLaunchModelPreload()

        guard shouldTerminateEngine else { return }
        scheduleEngineTermination()
    }

    func cancelLaunchModelPreloadForForegroundUse() async {
        guard launchModelPreloadTask != nil || isPreloadingLocalModel else { return }

        let task = launchModelPreloadTask
        task?.cancel()
        launchModelPreloadTask = nil
        let shouldTerminateEngine = isPreloadingLocalModel
        finishLaunchModelPreload()

        if shouldTerminateEngine {
            await vlmExecutor.terminate()
        }

        await task?.value
    }

    func prepareLaunchModelPreloadForForegroundUse(_ request: ChatGenerationRequest) async {
        guard launchModelPreloadTask != nil || isPreloadingLocalModel else { return }

        guard shouldAwaitLaunchModelPreload(for: request),
              let task = launchModelPreloadTask else {
            await cancelLaunchModelPreloadForForegroundUse()
            return
        }

        await task.value
    }

    private func shouldAwaitLaunchModelPreload(for request: ChatGenerationRequest) -> Bool {
        guard isPreloadingLocalModel,
              !request.isImageGeneration,
              !request.isSpeechGeneration,
              !request.isMusicGeneration,
              let progress = modelLoadProgress else {
            return false
        }

        let profile = request.profile(for: .chat)
        return progress.modelId == profile.modelId && progress.backend == profile.backend
    }

    private var isLaunchModelPreloadEnabled: Bool {
        if userDefaults.object(forKey: Self.launchModelPreloadEnabledKey) == nil {
            return true
        }

        return userDefaults.bool(forKey: Self.launchModelPreloadEnabledKey)
    }

    private var shouldSkipLaunchPreloadForSystemPressure: Bool {
        launchModelPreloadPressureCheck()
    }

    private func preloadSelectedLaunchModelIfEligible() async {
        guard isLaunchModelPreloadEnabled,
              !shouldSkipLaunchPreloadForSystemPressure,
              !isInputDisabled,
              launchModelPreloadTask != nil else {
            finishLaunchModelPreload()
            return
        }

        _ = await selectDownloadedDefaultModelIfNeeded(for: .vision)
        let profile = profile(for: .chat)
        guard profile.modality == .vision,
              profile.backend == .vlm || profile.backend == .llm,
              launchModelPreloadRuntimeCompatibilityCheck(profile),
              !isLoadedEngineModel(modelId: profile.modelId, backend: profile.backend),
              await isModelDownloadedOffMain(model: profile.downloadableModel) else {
            finishLaunchModelPreload()
            return
        }

        do {
            try Task.checkCancellation()
            isPreloadingLocalModel = true
            setActiveEngineModel(name: profile.name, role: .chat)
            loadingMessage = "Preparing \(profile.name)..."
            modelLoadProgress = ModelLoadProgress(
                modelId: profile.modelId,
                backend: profile.backend,
                phase: .warming,
                detail: "Preparing \(profile.name) in the background"
            )

            try await runtimeManager.initialize()
            try Task.checkCancellation()
            try await vlmExecutor.preload(modelId: profile.modelId, backend: profile.backend)
            finishLaunchModelPreload()
        } catch is CancellationError {
            finishLaunchModelPreload()
        } catch {
            localEngineErrorMessage = nil
            finishLaunchModelPreload()
        }
    }

    private func finishLaunchModelPreload() {
        launchModelPreloadTask = nil
        isPreloadingLocalModel = false

        if !isGenerating && !isModelLoading && !isPythonLoading && !isDraftingMusicLyrics {
            loadingMessage = ""
            modelLoadProgress = nil
            generationProgress = nil
        }
    }

    @discardableResult
    func selectDownloadedDefaultModelIfNeeded(for modality: ModelModality) async -> Bool {
        if let storedProfile = modelSelectionStore.storedProfile(for: modality),
           await isModelDownloadedOffMain(model: storedProfile.downloadableModel) {
            return false
        }

        let sortedProfiles = ModelCapabilityProfile.sortedProfiles(for: modality)
        let compatibleProfiles = sortedProfiles.filter { $0.isRuntimeCompatible() }
        let candidateProfiles = compatibleProfiles.isEmpty ? sortedProfiles : compatibleProfiles

        for profile in candidateProfiles {
            guard await isModelDownloadedOffMain(model: profile.downloadableModel) else {
                continue
            }

            modelSelectionStore.setSelectedModelId(profile.modelId, for: modality)
            modelSelectionRevision += 1
            return true
        }

        return false
    }

    private func refreshSelectedDownloadRequirement(
        _ requirement: DownloadableModel?,
        refreshToken: UUID,
        tool: Tool
    ) async {
        guard isActiveDownloadStatusRefresh(refreshToken, tool: tool) else { return }
        guard let requirement else {
            if pendingEngineDownloadReason == .preflight {
                clearPendingEngineDownloadModel()
            }
            return
        }

        if await isModelDownloadedOffMain(model: requirement) {
            guard isActiveDownloadStatusRefresh(refreshToken, tool: tool) else { return }
            if pendingEngineDownloadReason == .preflight {
                clearPendingEngineDownloadModel()
            }
            return
        }

        guard isActiveDownloadStatusRefresh(refreshToken, tool: tool) else { return }
        if pendingEngineDownloadReason == .generation,
           pendingEngineDownloadModel?.modelId != requirement.modelId,
           selectedTool == .auto || selectedTool == .chat || selectedTool == .research {
            return
        }

        if pendingEngineDownloadModel?.modelId != requirement.modelId || pendingEngineDownloadReason != .preflight {
            pendingEngineDownloadModel = requirement
            pendingEngineDownloadDetail = nil
            pendingEngineDownloadReason = .preflight
            startPendingDownloadMonitor(for: requirement)
        }
    }

    private func isActiveDownloadStatusRefresh(_ token: UUID, tool: Tool) -> Bool {
        downloadStatusRefreshToken == token && selectedTool == tool
    }

    func downloadRequirementForCurrentSelection() -> DownloadableModel? {
        downloadRequirement(for: selectedTool)
    }

    func downloadRequirement(for tool: Tool) -> DownloadableModel? {
        profile(for: tool).downloadableModel
    }

    func modelModality(for tool: Tool) -> ModelModality {
        ChatGenerationRequest.modelModality(for: tool)
    }

    func tool(for modality: ModelModality) -> Tool {
        switch modality {
        case .vision:
            return .chat
        case .image:
            return .image
        case .audio:
            return .tts
        case .music:
            return .music
        }
    }

    func profile(for tool: Tool) -> ModelCapabilityProfile {
        let modality = modelModality(for: tool)
        if let profile = modelSelectionStore.selectedProfile(for: modality) {
            return profile
        }

        return ModelCapabilityProfile.fallbackProfile(for: modality)
    }

    func isModelProfileSelected(_ profile: ModelCapabilityProfile) -> Bool {
        self.profile(for: selectedTool).modelId == profile.modelId
    }

    func selectModelProfile(_ profile: ModelCapabilityProfile) {
        if profile.modality == .vision {
            cancelLaunchModelPreload()
        }
        guard !isInputDisabled else { return }
        modelSelectionStore.setSelectedModelId(profile.modelId, for: profile.modality)
        if profile.modality == .music, !profile.supportsMusicLyrics {
            selectMusicVocalMode(.instrumental)
        }
        modelSelectionRevision += 1
        isModelMenuOpen = false
        refreshLocalEngineDownloadStatus()
    }

    func parameterValue(for profile: ModelCapabilityProfile, key: String) -> String {
        _ = modelParameterRevision
        return modelParameterStore.values(for: profile)[key]
            ?? profile.parameterDefinition(key: key)?.defaultValue
            ?? ""
    }

    func setParameterValue(_ value: String, for definition: ModelParameterDefinition, profile: ModelCapabilityProfile) {
        guard !isInputDisabled else { return }

        let resolvedValue: String
        switch definition.type {
        case .decimal, .integer:
            resolvedValue = definition.clampedString(Double(value) ?? Double(definition.defaultValue) ?? 0)
        case .boolean, .option, .text, .filePath:
            resolvedValue = value
        }

        modelParameterStore.setValue(resolvedValue, for: definition.key, modelId: profile.modelId)
        modelParameterRevision += 1
    }

    func applyParameterPreset(_ preset: ModelParameterPreset, to profile: ModelCapabilityProfile) {
        guard !isInputDisabled else { return }

        modelParameterStore.applyPreset(preset, to: profile)
        modelParameterRevision += 1
    }

    func resetParameters(for profile: ModelCapabilityProfile) {
        guard !isInputDisabled else { return }

        modelParameterStore.reset(profile: profile)
        modelParameterRevision += 1
    }

    func clearPendingEngineDownloadModel() {
        pendingEngineDownloadModel = nil
        pendingEngineDownloadDetail = nil
        pendingEngineDownloadReason = nil
        pendingDownloadMonitorTask?.cancel()
        pendingDownloadMonitorTask = nil
    }

    func requestDownloadBeforeUse(model: DownloadableModel, detail: String? = nil) {
        modelDownloadRequest = model
        pendingEngineDownloadModel = model
        pendingEngineDownloadDetail = detail
        pendingEngineDownloadReason = .generation
        startPendingDownloadMonitor(for: model)
        loadingMessage = ""
        modelLoadProgress = nil
        generationProgress = nil
    }

    func clearModelDownloadRequest() {
        modelDownloadRequest = nil
    }

    func modelDownloadRequiredMessage(for model: DownloadableModel, operation: String) -> String {
        "Model download required: \(operation) needs \(model.name) (\(String(format: "%.1f", model.totalDownloadSizeGB)) GB)."
    }

    func isModelDownloadedOffMain(model: DownloadableModel) async -> Bool {
        await runtimeManager.isModelDownloadedOffMain(model: model)
    }

    func requireDownloadedModel(
        model: DownloadableModel,
        operation: String,
        detail: String? = nil
    ) async -> Bool {
        guard !(await isModelDownloadedOffMain(model: model)) else {
            clearPendingEngineDownloadModel(matching: model.modelId)
            return true
        }

        requestDownloadBeforeUse(model: model, detail: detail)
        isGenerating = false
        isModelLoading = false
        streamingMessageId = nil
        generationTask = nil
        return false
    }

    func operationNameForCurrentSelection() -> String {
        operationName(for: selectedTool)
    }

    func operationName(for tool: Tool) -> String {
        switch tool {
        case .auto, .chat:
            return "Chat"
        case .image:
            return "Image generation"
        case .tts:
            return "Speech generation"
        case .music:
            return "Music generation"
        case .research:
            return "Research"
        }
    }

    @discardableResult
    func ensureLocalRuntimeReady(
        progress: ModelLoadProgress? = nil,
        generationID: UUID? = nil
    ) async throws -> Bool {
        if runtimeManager.state != .ready {
            isPythonLoading = true
            loadingMessage = "Initializing Python runtime..."
            modelLoadProgress = progress
            do {
                try await runtimeManager.initialize()
            } catch {
                clearRuntimeLoadingIfActive(generationID: generationID)
                throw error
            }
            guard ownsActiveGeneration(generationID) else { return false }
            do {
                try await vlmExecutor.initialize()
            } catch {
                clearRuntimeLoadingIfActive(generationID: generationID)
                throw error
            }
            guard ownsActiveGeneration(generationID) else { return false }
            isPythonLoading = false
            modelLoadProgress = nil
            generationProgress = nil
        }

        if !vlmExecutor.isReady {
            try await vlmExecutor.initialize()
            guard ownsActiveGeneration(generationID) else { return false }
        }
        return true
    }

    func setActiveEngineModel(name: String, role: LocalEngineModelRole) {
        activeEngineModelName = name
        activeEngineModelRole = role
        freedEngineModelName = nil
        localEngineErrorMessage = nil
    }

    private func clearRuntimeLoadingIfActive(generationID: UUID?) {
        guard ownsActiveGeneration(generationID) else { return }
        isPythonLoading = false
        modelLoadProgress = nil
        generationProgress = nil
    }

    func localEngineModelRole(for plan: ChatMediaToolExecutionPlan) -> LocalEngineModelRole {
        switch plan.functionName {
        case "generate_image":
            return .image
        case "create_speech":
            return .speech
        case "generate_music":
            return .music
        default:
            return plan.attachmentKind == .image ? .image : .speech
        }
    }

    var loadedEngineModelName: String? {
        guard vlmExecutor.isModelLoaded,
              let modelId = vlmExecutor.currentModelId else {
            return nil
        }

        return downloadableModelName(modelId: modelId)
    }

    var loadedEngineModelRole: LocalEngineModelRole? {
        guard vlmExecutor.isModelLoaded,
              let backend = vlmExecutor.currentModelBackend else {
            return nil
        }

        return localEngineModelRole(for: backend)
    }

    func isLoadedEngineModel(modelId: String, backend: RuntimeBackend) -> Bool {
        vlmExecutor.isModelLoaded
            && vlmExecutor.currentModelId == modelId
            && vlmExecutor.currentModelBackend == backend
    }

    private func downloadableModelName(modelId: String) -> String {
        DownloadableModel.embeddedModel(modelId: modelId)?.name
            ?? modelId
    }

    private func localEngineModelRole(for backend: RuntimeBackend) -> LocalEngineModelRole {
        switch backend {
        case .image:
            return .image
        case .audio:
            return .speech
        case .music:
            return .music
        case .vlm, .llm:
            return .chat
        }
    }

    private func startPendingDownloadMonitor(for model: DownloadableModel) {
        pendingDownloadMonitorTask?.cancel()
        pendingDownloadMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.pendingEngineDownloadModel?.modelId == model.modelId else {
                    return
                }

                if await self.isModelDownloadedOffMain(model: model) {
                    self.clearPendingEngineDownloadModel(matching: model.modelId)
                    return
                }

                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func clearPendingEngineDownloadModel(matching modelId: String) {
        guard pendingEngineDownloadModel?.modelId == modelId else { return }
        clearPendingEngineDownloadModel()
    }

    func selectTool(_ tool: Tool) {
        guard !isInputDisabled else { return }

        selectedTool = tool
        if tool == .music {
            musicIntentState = .needsInstrumentalOrVocals
            musicVocalMode = .auto
        } else {
            activeMusicGenerationDraft = nil
            isMusicLyricsEditorVisible = false
        }
        isToolMenuOpen = false
        refreshLocalEngineDownloadStatus()
    }

    func toggleToolMenu() {
        guard !isInputDisabled else {
            isToolMenuOpen = false
            return
        }

        isToolMenuOpen.toggle()
        if isToolMenuOpen {
            isModelMenuOpen = false
        }
    }

    func toggleModelMenu() {
        guard !isInputDisabled else {
            isModelMenuOpen = false
            return
        }

        isModelMenuOpen.toggle()
        if isModelMenuOpen {
            isToolMenuOpen = false
        }
    }

    func closeMenus() {
        isToolMenuOpen = false
        isModelMenuOpen = false
    }

    func focusComposer() {
        guard !isInputDisabled else { return }
        composerFocusRequest &+= 1
    }
}
