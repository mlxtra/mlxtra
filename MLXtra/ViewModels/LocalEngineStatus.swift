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

struct GenerationProgress: Codable, Equatable {
    let modelId: String
    let backend: RuntimeBackend
    let phase: String
    let message: String?
    let fractionCompleted: Double?
    let isEstimated: Bool

    enum CodingKeys: String, CodingKey {
        case modelId
        case backend
        case phase
        case message
        case fractionCompleted
        case isEstimated
    }

    init(
        modelId: String,
        backend: RuntimeBackend,
        phase: String,
        message: String? = nil,
        fractionCompleted: Double? = nil,
        isEstimated: Bool = false
    ) {
        self.modelId = modelId
        self.backend = backend
        self.phase = phase.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "generating"
        self.message = message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.fractionCompleted = fractionCompleted.map { min(max($0, 0), 1) }
        self.isEstimated = isEstimated
    }

    static func bridgeEvent(
        _ json: [String: Any],
        fallbackModelId: String,
        fallbackBackend: RuntimeBackend
    ) -> GenerationProgress {
        let modelId = (json["model"] as? String)?.nilIfEmpty ?? fallbackModelId
        let backend = (json["backend"] as? String)
            .flatMap(RuntimeBackend.init(rawValue:))
            ?? fallbackBackend
        let phase = (json["phase"] as? String)
            ?? (json["status"] as? String)
            ?? "generating"
        let message = (json["message"] as? String)
            ?? (json["detail"] as? String)

        return GenerationProgress(
            modelId: modelId,
            backend: backend,
            phase: phase,
            message: message,
            fractionCompleted: bridgeFraction(from: json),
            isEstimated: boolValue(json["estimated"]) ?? false
        )
    }

    var percent: Int? {
        fractionCompleted.map { min(max(Int(($0 * 100).rounded()), 0), 100) }
    }

    var percentText: String? {
        guard let percent else { return nil }
        return "\(isEstimated ? "~" : "")\(percent)%"
    }

    var displayMessage: String {
        message ?? phaseDisplayTitle
    }

    var displayDetail: String {
        guard let percentText else { return displayMessage }
        return "\(displayMessage) (\(percentText))"
    }

    func compactTitle(modelName: String) -> String {
        guard let percentText else {
            return phaseDisplayTitle
        }

        return "\(phaseDisplayTitle) \(percentText)"
    }

    private var phaseDisplayTitle: String {
        let normalized = phase
            .replacingOccurrences(of: "-", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "preparing", "starting":
            return "Preparing"
        case "denoising", "diffusing":
            return "Generating"
        case "synthesizing", "generating_speech":
            return "Creating speech"
        case "rendering", "decoding", "writing", "saving", "finalizing":
            return "Finalizing"
        case "complete", "completed", "ready":
            return "Complete"
        default:
            let title = normalized
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            return title.nilIfEmpty ?? "Generating"
        }
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

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "y":
                return true
            case "false", "0", "no", "n":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }
}

struct LocalEngineStatus: Equatable {
    enum State: Equatable {
        case idle
        case preparing
        case preloading
        case loadingModel
        case generating
        case terminating
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
    let generationProgress: GenerationProgress?

    var progressFractionCompleted: Double? {
        loadProgress?.fractionCompleted ?? generationProgress?.fractionCompleted
    }

    var accessibilityProgressLabel: String {
        if state == .preloading {
            return "Model preparing in background"
        }

        if generationProgress != nil {
            return "Generation progress"
        }

        return "Model loading"
    }

    static func resolve(
        runtimeState: RuntimeManager.RuntimeState,
        isPythonLoading: Bool,
        isModelLoading: Bool,
        isPreloadingLocalModel: Bool = false,
        isGenerating: Bool,
        isTerminatingLocalEngine: Bool = false,
        loadingMessage: String,
        loadProgress: ModelLoadProgress? = nil,
        generationProgress: GenerationProgress? = nil,
        isExecutorReady: Bool,
        isModelLoaded: Bool,
        selectedModelName: String,
        activeModelName: String?,
        activeModelRole: LocalEngineModelRole,
        pendingDownloadModelId: String?,
        pendingDownloadModelName: String?,
        pendingDownloadDetail: String? = nil,
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
                loadProgress: nil,
                generationProgress: nil
            )
        }

        if isPreloadingLocalModel {
            return LocalEngineStatus(
                state: .preloading,
                title: "Preparing in background",
                detail: loadProgress?.detail ?? (trimmedLoadingMessage.isEmpty ? "\(modelName) will be ready faster." : trimmedLoadingMessage),
                systemImage: "bolt",
                tone: .neutral,
                primaryAction: nil,
                primaryActionModelId: nil,
                canFreeMemory: false,
                isVisibleInComposer: true,
                loadProgress: loadProgress,
                generationProgress: nil
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
                loadProgress: loadProgress,
                generationProgress: nil
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
                loadProgress: loadProgress,
                generationProgress: nil
            )
        }

        if isGenerating {
            return LocalEngineStatus(
                state: .generating,
                title: "Generating...",
                detail: generationProgress?.displayDetail ?? (trimmedLoadingMessage.isEmpty ? activeModelRole.generatingDetail : trimmedLoadingMessage),
                systemImage: "sparkles",
                tone: .accent,
                primaryAction: nil,
                primaryActionModelId: nil,
                canFreeMemory: false,
                isVisibleInComposer: true,
                loadProgress: nil,
                generationProgress: generationProgress
            )
        }

        if isTerminatingLocalEngine {
            return LocalEngineStatus(
                state: .terminating,
                title: "Stopping...",
                detail: "Stopping the local engine and cleaning up the running process.",
                systemImage: "stop.circle",
                tone: .accent,
                primaryAction: nil,
                primaryActionModelId: nil,
                canFreeMemory: false,
                isVisibleInComposer: true,
                loadProgress: nil,
                generationProgress: nil
            )
        }

        if let pendingDownloadModelName {
            return LocalEngineStatus(
                state: .needsDownload,
                title: "Needs download",
                detail: pendingDownloadDetail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? "\(pendingDownloadModelName) needs to be downloaded before use.",
                systemImage: "arrow.down.circle",
                tone: .warning,
                primaryAction: .openModels,
                primaryActionModelId: pendingDownloadModelId,
                canFreeMemory: false,
                isVisibleInComposer: true,
                loadProgress: nil,
                generationProgress: nil
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
                loadProgress: nil,
                generationProgress: nil
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
                loadProgress: nil,
                generationProgress: nil
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
                loadProgress: nil,
                generationProgress: nil
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
            loadProgress: nil,
            generationProgress: nil
        )
    }

    private static func resolvedErrorMessage(
        runtimeState: RuntimeManager.RuntimeState,
        lastErrorMessage: String?
    ) -> String? {
        if let trimmedLastErrorMessage = lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedLastErrorMessage.isEmpty {
            return trimmedLastErrorMessage
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
