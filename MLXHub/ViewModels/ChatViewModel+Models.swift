import Foundation

@MainActor
extension ChatViewModel {
    var localEngineStatus: LocalEngineStatus {
        LocalEngineStatus.resolve(
            runtimeState: runtimeManager.state,
            isPythonLoading: isPythonLoading,
            isModelLoading: isModelLoading,
            isGenerating: isGenerating,
            loadingMessage: loadingMessage,
            loadProgress: modelLoadProgress,
            isExecutorReady: vlmExecutor.isReady,
            isModelLoaded: vlmExecutor.isModelLoaded,
            selectedModelName: activeModelProfile.name,
            activeModelName: loadedEngineModelName ?? activeEngineModelName,
            activeModelRole: loadedEngineModelRole ?? activeEngineModelRole,
            pendingDownloadModelId: pendingEngineDownloadModel?.modelId,
            pendingDownloadModelName: pendingEngineDownloadModel?.name,
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

        let freedModelName = loadedEngineModelName ?? activeEngineModelName ?? activeModelProfile.name
        isPythonLoading = false
        isModelLoading = false
        isGenerating = false
        loadingMessage = ""
        modelLoadProgress = nil
        localEngineErrorMessage = nil

        Task {
            await vlmExecutor.terminate()
            activeEngineModelName = nil
            activeEngineModelRole = .chat
            self.freedEngineModelName = freedModelName
        }
    }

    func restartLocalEngine() {
        guard !isInputDisabled else { return }

        isPythonLoading = true
        loadingMessage = "Preparing local engine..."
        modelLoadProgress = nil
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
            } catch {
                isPythonLoading = false
                loadingMessage = ""
                modelLoadProgress = nil
                localEngineErrorMessage = "The local engine stopped. Restart to continue."
            }
        }
    }

    func refreshLocalEngineDownloadStatus() {
        let currentPendingModel = pendingEngineDownloadModel
        let selectionRequirement = downloadRequirementForCurrentSelection()

        Task {
            if let currentPendingModel,
               await isModelDownloadedOffMain(modelId: currentPendingModel.modelId),
               self.pendingEngineDownloadModel?.modelId == currentPendingModel.modelId {
                self.clearPendingEngineDownloadModel(matching: currentPendingModel.modelId)
            }

            await refreshSelectedDownloadRequirement(selectionRequirement)
        }
    }

    private func refreshSelectedDownloadRequirement(_ requirement: DownloadableModel?) async {
        guard let requirement else {
            if pendingEngineDownloadReason == .preflight {
                clearPendingEngineDownloadModel()
            }
            return
        }

        if await isModelDownloadedOffMain(modelId: requirement.modelId) {
            if pendingEngineDownloadReason == .preflight {
                clearPendingEngineDownloadModel()
            }
            return
        }

        if pendingEngineDownloadReason == .generation,
           pendingEngineDownloadModel?.modelId != requirement.modelId,
           selectedTool == .auto || selectedTool == .chat || selectedTool == .research {
            return
        }

        if pendingEngineDownloadModel?.modelId != requirement.modelId || pendingEngineDownloadReason != .preflight {
            pendingEngineDownloadModel = requirement
            pendingEngineDownloadReason = .preflight
            startPendingDownloadMonitor(for: requirement)
        }
    }

    func downloadRequirementForCurrentSelection() -> DownloadableModel? {
        downloadRequirement(for: selectedTool)
    }

    func downloadRequirement(for tool: Tool) -> DownloadableModel? {
        profile(for: tool).downloadableModel
    }

    func modelModality(for tool: Tool) -> ModelModality {
        switch tool {
        case .auto, .chat, .research:
            return .vision
        case .image:
            return .image
        case .tts:
            return .audio
        case .music:
            return .music
        }
    }

    func profile(for tool: Tool) -> ModelCapabilityProfile {
        let modality = modelModality(for: tool)
        if let profile = modelSelectionStore.selectedProfile(for: modality) {
            return profile
        }

        return ModelCapabilityProfile.profiles(for: modality).first
            ?? ModelCapabilityProfile.embedded.first!
    }

    func isModelProfileSelected(_ profile: ModelCapabilityProfile) -> Bool {
        self.profile(for: selectedTool).modelId == profile.modelId
    }

    func selectModelProfile(_ profile: ModelCapabilityProfile) {
        modelSelectionStore.setSelectedModelId(profile.modelId, for: profile.modality)
        if let aiModel = profile.aiModel {
            selectedModel = aiModel
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
        let resolvedValue: String
        switch definition.type {
        case .decimal, .integer:
            resolvedValue = definition.clampedString(Double(value) ?? Double(definition.defaultValue) ?? 0)
        case .boolean, .option, .text:
            resolvedValue = value
        }

        modelParameterStore.setValue(resolvedValue, for: definition.key, modelId: profile.modelId)
        modelParameterRevision += 1
    }

    func applyParameterPreset(_ preset: ModelParameterPreset, to profile: ModelCapabilityProfile) {
        modelParameterStore.applyPreset(preset, to: profile)
        modelParameterRevision += 1
    }

    func resetParameters(for profile: ModelCapabilityProfile) {
        modelParameterStore.reset(profile: profile)
        modelParameterRevision += 1
    }

    func clearPendingEngineDownloadModel() {
        pendingEngineDownloadModel = nil
        pendingEngineDownloadReason = nil
        pendingDownloadMonitorTask?.cancel()
        pendingDownloadMonitorTask = nil
    }

    func requestDownloadBeforeUse(model: DownloadableModel) {
        modelDownloadRequest = model
        pendingEngineDownloadModel = model
        pendingEngineDownloadReason = .generation
        startPendingDownloadMonitor(for: model)
        loadingMessage = ""
        modelLoadProgress = nil
    }

    func clearModelDownloadRequest() {
        modelDownloadRequest = nil
    }

    func modelDownloadRequiredMessage(for model: DownloadableModel, operation: String) -> String {
        "Model download required: \(operation) needs \(model.name) (\(String(format: "%.1f", model.downloadSizeGB)) GB)."
    }

    func isModelDownloadedOffMain(modelId: String) async -> Bool {
        await runtimeManager.isModelDownloadedOffMain(modelId: modelId)
    }

    func requireDownloadedModel(model: DownloadableModel, operation: String) async -> Bool {
        guard !(await isModelDownloadedOffMain(modelId: model.modelId)) else {
            clearPendingEngineDownloadModel(matching: model.modelId)
            return true
        }

        requestDownloadBeforeUse(model: model)
        isGenerating = false
        isModelLoading = false
        streamingMessageId = nil
        generationTask = nil
        return false
    }

    func operationNameForCurrentSelection() -> String {
        switch selectedTool {
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

    func ensureLocalRuntimeReady() async throws {
        if runtimeManager.state != .ready {
            isPythonLoading = true
            loadingMessage = "Initializing Python runtime..."
            modelLoadProgress = nil
            try await runtimeManager.initialize()
            try await vlmExecutor.initialize()
            isPythonLoading = false
            modelLoadProgress = nil
        }

        if !vlmExecutor.isReady {
            try await vlmExecutor.initialize()
        }
    }

    func setActiveEngineModel(name: String, role: LocalEngineModelRole) {
        activeEngineModelName = name
        activeEngineModelRole = role
        freedEngineModelName = nil
        localEngineErrorMessage = nil
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
            ?? AIModel.allCases.first { $0.modelId == modelId }?.displayName
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

                if await self.isModelDownloadedOffMain(modelId: model.modelId) {
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

    func selectModel(_ model: AIModel) {
        selectedModel = model
        modelSelectionStore.setSelectedModelId(model.modelId, for: .vision)
        modelSelectionRevision += 1
        isModelMenuOpen = false
        refreshLocalEngineDownloadStatus()
    }

    func toggleToolMenu() {
        isToolMenuOpen.toggle()
        if isToolMenuOpen {
            isModelMenuOpen = false
        }
    }

    func toggleModelMenu() {
        isModelMenuOpen.toggle()
        if isModelMenuOpen {
            isToolMenuOpen = false
        }
    }

    func closeMenus() {
        isToolMenuOpen = false
        isModelMenuOpen = false
    }
}
