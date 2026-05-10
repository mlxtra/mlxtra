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

struct ModelLoadProgress: Equatable {
    enum Phase: String, Equatable {
        case preparing
        case loadingWeights = "loading_weights"
        case initializing
        case warming
        case ready
        case unknown

        init(bridgeValue: String?) {
            let normalized = bridgeValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")

            switch normalized {
            case "preparing", "starting", "queued":
                self = .preparing
            case "loading_weights", "loading", "downloading":
                self = .loadingWeights
            case "initializing", "waiting_for_models", "components_ready":
                self = .initializing
            case "warming", "warmup", "warming_up":
                self = .warming
            case "ready", "loaded":
                self = .ready
            default:
                self = .unknown
            }
        }

        var displayTitle: String {
            switch self {
            case .preparing:
                return "Preparing runtime"
            case .loadingWeights:
                return "Loading weights"
            case .initializing:
                return "Initializing model"
            case .warming:
                return "Warming model"
            case .ready:
                return "Ready"
            case .unknown:
                return "Loading model"
            }
        }
    }

    let modelId: String
    let backend: RuntimeBackend
    let phase: Phase
    let fractionCompleted: Double?
    let detail: String?

    init(
        modelId: String,
        backend: RuntimeBackend,
        phase: Phase,
        fractionCompleted: Double? = nil,
        detail: String? = nil
    ) {
        self.modelId = modelId
        self.backend = backend
        self.phase = phase
        self.fractionCompleted = fractionCompleted.map { min(max($0, 0), 1) }
        self.detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func bridgeEvent(
        _ json: [String: Any],
        fallbackModelId: String,
        fallbackBackend: RuntimeBackend
    ) -> ModelLoadProgress {
        let rawPhase = (json["phase"] as? String) ?? (json["status"] as? String)
        let modelId = (json["model"] as? String)?.nilIfEmpty ?? fallbackModelId
        let backend = (json["backend"] as? String)
            .flatMap(RuntimeBackend.init(rawValue:))
            ?? fallbackBackend
        let detail = (json["detail"] as? String)
            ?? (json["message"] as? String)
            ?? (json["status"] as? String)

        return ModelLoadProgress(
            modelId: modelId,
            backend: backend,
            phase: Phase(bridgeValue: rawPhase),
            fractionCompleted: bridgeFraction(from: json),
            detail: detail
        )
    }

    private static func bridgeFraction(from json: [String: Any]) -> Double? {
        if let fraction = doubleValue(json["fraction"]) ?? doubleValue(json["fraction_completed"]) {
            return min(max(fraction, 0), 1)
        }

        if let percent = doubleValue(json["percent"]) ?? doubleValue(json["percentage"]) {
            return min(max(percent / 100, 0), 1)
        }

        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number.isFinite ? number : nil
        case let number as Float:
            let double = Double(number)
            return double.isFinite ? double : nil
        case let number as Int:
            return Double(number)
        case let number as NSNumber:
            let double = number.doubleValue
            return double.isFinite ? double : nil
        case let string as String:
            let double = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
            return double?.isFinite == true ? double : nil
        default:
            return nil
        }
    }

    func compactTitle(modelName: String) -> String {
        let shortName = modelName.split(separator: " ").first.map(String.init) ?? "Model"

        switch phase {
        case .preparing:
            return "Preparing \(shortName)"
        case .loadingWeights:
            return "Loading \(shortName)"
        case .initializing:
            return "Initializing \(shortName)"
        case .warming:
            return "Warming \(shortName)"
        case .ready:
            return "Ready"
        case .unknown:
            return "Loading \(shortName)"
        }
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
    let primaryActionModelId: String?
    let canFreeMemory: Bool
    let isVisibleInComposer: Bool
    let loadProgress: ModelLoadProgress?

    static func resolve(
        runtimeState: RuntimeManager.RuntimeState,
        isPythonLoading: Bool,
        isModelLoading: Bool,
        isGenerating: Bool,
        loadingMessage: String,
        loadProgress: ModelLoadProgress? = nil,
        isExecutorReady: Bool,
        isModelLoaded: Bool,
        selectedModelName: String,
        activeModelName: String?,
        activeModelRole: LocalEngineModelRole,
        pendingDownloadModelId: String?,
        pendingDownloadModelName: String?,
        freedModelName: String?,
        lastErrorMessage: String?
    ) -> LocalEngineStatus {
        let modelName = activeModelName ?? selectedModelName
        let trimmedLoadingMessage = loadingMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        if let errorMessage = resolvedErrorMessage(runtimeState: runtimeState, lastErrorMessage: lastErrorMessage) {
            return LocalEngineStatus(
                state: .needsAttention,
                title: "Needs attention",
                detail: errorMessage,
                systemImage: "exclamationmark.triangle",
                tone: .danger,
                primaryAction: .restart,
                primaryActionModelId: nil,
                canFreeMemory: false,
                isVisibleInComposer: true,
                loadProgress: nil
            )
        }

        if isPythonLoading || runtimeState.isPreparing {
            return LocalEngineStatus(
                state: .preparing,
                title: "Preparing local engine",
                detail: loadProgress?.detail ?? (trimmedLoadingMessage.isEmpty ? "Getting the local engine ready." : trimmedLoadingMessage),
                systemImage: "bolt.horizontal.circle",
                tone: .accent,
                primaryAction: nil,
                primaryActionModelId: nil,
                canFreeMemory: false,
                isVisibleInComposer: true,
                loadProgress: loadProgress
            )
        }

        if isModelLoading {
            return LocalEngineStatus(
                state: .loadingModel,
                title: activeModelRole.loadingTitle(modelName: modelName),
                detail: loadProgress?.detail ?? (trimmedLoadingMessage.isEmpty ? "This can take a moment the first time." : trimmedLoadingMessage),
                systemImage: "clock",
                tone: .accent,
                primaryAction: nil,
                primaryActionModelId: nil,
                canFreeMemory: false,
                isVisibleInComposer: true,
                loadProgress: loadProgress
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
                primaryActionModelId: nil,
                canFreeMemory: false,
                isVisibleInComposer: true,
                loadProgress: nil
            )
        }

        if let pendingDownloadModelName {
            return LocalEngineStatus(
                state: .needsDownload,
                title: "Needs download",
                detail: "\(pendingDownloadModelName) needs to be downloaded before use.",
                systemImage: "arrow.down.circle",
                tone: .warning,
                primaryAction: .openModels,
                primaryActionModelId: pendingDownloadModelId,
                canFreeMemory: false,
                isVisibleInComposer: true,
                loadProgress: nil
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
                primaryActionModelId: nil,
                canFreeMemory: false,
                isVisibleInComposer: true,
                loadProgress: nil
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
                primaryActionModelId: nil,
                canFreeMemory: true,
                isVisibleInComposer: true,
                loadProgress: nil
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
                primaryActionModelId: nil,
                canFreeMemory: false,
                isVisibleInComposer: false,
                loadProgress: nil
            )
        }

        return LocalEngineStatus(
            state: .idle,
            title: "Local model",
            detail: "\(modelName) will prepare when you send a message.",
            systemImage: "circle",
            tone: .neutral,
            primaryAction: nil,
            primaryActionModelId: nil,
            canFreeMemory: false,
            isVisibleInComposer: false,
            loadProgress: nil
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
