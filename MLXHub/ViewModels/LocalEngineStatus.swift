import Foundation

enum LocalEngineModelRole: Equatable {
    case chat
    case image
    case speech
    case music

    func loadingTitle(modelName: String?) -> String {
        switch self {
        case .chat:
            return "Loading \(shortModelName(modelName))"
        case .image:
            return "Loading image model"
        case .speech:
            return "Loading speech model"
        case .music:
            return "Loading music model"
        }
    }

    func readyTitle(modelName: String?) -> String {
        switch self {
        case .chat:
            return "\(shortModelName(modelName)) is ready"
        case .image:
            return "Image model is ready"
        case .speech:
            return "Speech model is ready"
        case .music:
            return "Music model is ready"
        }
    }

    var generatingDetail: String {
        switch self {
        case .chat:
            return "Writing a response."
        case .image:
            return "Creating an image."
        case .speech:
            return "Creating speech audio."
        case .music:
            return "Creating music."
        }
    }

    private func shortModelName(_ modelName: String?) -> String {
        guard let modelName,
              let firstWord = modelName.split(separator: " ").first else {
            return "Model"
        }
        return String(firstWord)
    }
}

struct LocalEngineStatus: Equatable {
    enum State: Equatable {
        case idle
        case preparing
        case loadingModel
        case generating
        case ready
        case needsDownload
        case needsAttention
        case memoryFreed
    }

    enum Tone: Equatable {
        case neutral
        case accent
        case success
        case warning
        case danger
    }

    enum Action: Equatable {
        case openModels
        case restart
    }

    let state: State
    let title: String
    let detail: String
    let systemImage: String
    let tone: Tone
    let primaryAction: Action?
    let canFreeMemory: Bool
    let isVisibleInComposer: Bool

    static func resolve(
        runtimeState: RuntimeManager.RuntimeState,
        isPythonLoading: Bool,
        isModelLoading: Bool,
        isGenerating: Bool,
        loadingMessage: String,
        isExecutorReady: Bool,
        isModelLoaded: Bool,
        selectedModelName: String,
        activeModelName: String?,
        activeModelRole: LocalEngineModelRole,
        pendingDownloadModelName: String?,
        freedModelName: String?,
        lastErrorMessage: String?
    ) -> LocalEngineStatus {
        let modelName = activeModelName ?? selectedModelName
        let trimmedLoadingMessage = loadingMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        if let pendingDownloadModelName {
            return LocalEngineStatus(
                state: .needsDownload,
                title: "Needs download",
                detail: "\(pendingDownloadModelName) needs to be downloaded before use.",
                systemImage: "arrow.down.circle",
                tone: .warning,
                primaryAction: .openModels,
                canFreeMemory: false,
                isVisibleInComposer: true
            )
        }

        if let errorMessage = resolvedErrorMessage(runtimeState: runtimeState, lastErrorMessage: lastErrorMessage) {
            return LocalEngineStatus(
                state: .needsAttention,
                title: "Needs attention",
                detail: errorMessage,
                systemImage: "exclamationmark.triangle",
                tone: .danger,
                primaryAction: .restart,
                canFreeMemory: false,
                isVisibleInComposer: true
            )
        }

        if isPythonLoading || runtimeState.isPreparing {
            return LocalEngineStatus(
                state: .preparing,
                title: "Preparing local engine",
                detail: trimmedLoadingMessage.isEmpty ? "Getting the local engine ready." : trimmedLoadingMessage,
                systemImage: "bolt.horizontal.circle",
                tone: .accent,
                primaryAction: nil,
                canFreeMemory: false,
                isVisibleInComposer: true
            )
        }

        if isModelLoading {
            return LocalEngineStatus(
                state: .loadingModel,
                title: activeModelRole.loadingTitle(modelName: modelName),
                detail: trimmedLoadingMessage.isEmpty ? "This can take a moment the first time." : trimmedLoadingMessage,
                systemImage: "clock",
                tone: .accent,
                primaryAction: nil,
                canFreeMemory: false,
                isVisibleInComposer: true
            )
        }

        if isGenerating {
            return LocalEngineStatus(
                state: .generating,
                title: "Generating...",
                detail: trimmedLoadingMessage.isEmpty ? activeModelRole.generatingDetail : trimmedLoadingMessage,
                systemImage: "sparkles",
                tone: .accent,
                primaryAction: nil,
                canFreeMemory: false,
                isVisibleInComposer: true
            )
        }

        if let freedModelName, !isExecutorReady, !isModelLoaded {
            return LocalEngineStatus(
                state: .memoryFreed,
                title: "Memory freed",
                detail: "\(freedModelName) will load again when needed.",
                systemImage: "memorychip",
                tone: .neutral,
                primaryAction: nil,
                canFreeMemory: false,
                isVisibleInComposer: true
            )
        }

        if isExecutorReady && isModelLoaded {
            return LocalEngineStatus(
                state: .ready,
                title: activeModelRole.readyTitle(modelName: modelName),
                detail: "\(modelName) is using memory locally.",
                systemImage: "checkmark.circle",
                tone: .success,
                primaryAction: nil,
                canFreeMemory: true,
                isVisibleInComposer: true
            )
        }

        if isExecutorReady {
            return LocalEngineStatus(
                state: .idle,
                title: "Ready to load",
                detail: "\(modelName) will load when needed.",
                systemImage: "circle",
                tone: .neutral,
                primaryAction: nil,
                canFreeMemory: false,
                isVisibleInComposer: false
            )
        }

        return LocalEngineStatus(
            state: .idle,
            title: "Local model",
            detail: "\(modelName) will prepare when you send a message.",
            systemImage: "circle",
            tone: .neutral,
            primaryAction: nil,
            canFreeMemory: false,
            isVisibleInComposer: false
        )
    }

    private static func resolvedErrorMessage(
        runtimeState: RuntimeManager.RuntimeState,
        lastErrorMessage: String?
    ) -> String? {
        if let lastErrorMessage,
           !lastErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return lastErrorMessage
        }

        if case .error = runtimeState {
            return "The local engine stopped. Restart to continue."
        }

        return nil
    }
}

private extension RuntimeManager.RuntimeState {
    var isPreparing: Bool {
        switch self {
        case .checkingBundle, .extractingBundle, .startingPython:
            return true
        case .notInitialized, .ready, .error:
            return false
        }
    }
}
