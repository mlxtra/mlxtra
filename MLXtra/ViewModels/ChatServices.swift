@preconcurrency import Foundation

struct ChatPersistenceSnapshot: @unchecked Sendable {
    let chats: [Chat]
    let selectedChatId: UUID?
}

@MainActor
protocol ChatPersistenceServicing: AnyObject {
    var loadsConversationHistoryAsynchronously: Bool { get }
    func loadChats() -> [Chat]
    func loadConversationSnapshot() async -> ChatPersistenceSnapshot
    func saveChats(_ chats: [Chat])
    func scheduleSave(_ chats: [Chat], selectedChatId: UUID?)
    func flushPendingSave()
    func loadSelectedChatId() -> UUID?
    func saveSelectedChatId(_ selectedChatId: UUID?)
    func persistAttachments(_ urls: [URL], chatId: UUID, messageId: UUID) async -> [URL]
    func deleteAttachments(for chatId: UUID)
}

extension ChatPersistenceServicing {
    var loadsConversationHistoryAsynchronously: Bool { false }

    func loadConversationSnapshot() async -> ChatPersistenceSnapshot {
        ChatPersistenceSnapshot(chats: loadChats(), selectedChatId: loadSelectedChatId())
    }

    func scheduleSave(_ chats: [Chat], selectedChatId: UUID?) {
        saveChats(chats)
        saveSelectedChatId(selectedChatId)
    }

    func flushPendingSave() {}
}

@MainActor
protocol ChatModelExecuting: ModelExecutor {
    var isModelLoaded: Bool { get }
    var currentModelId: String? { get }
    var currentModelBackend: RuntimeBackend? { get }
    var delegate: VLMExecutionDelegate? { get set }
    func preload(modelId: String, backend: RuntimeBackend, parameters: [String: Any]?) async throws
}

extension ChatModelExecuting {
    func preload(modelId: String, backend: RuntimeBackend) async throws {
        try await preload(modelId: modelId, backend: backend, parameters: nil)
    }

    func preload(modelId: String, backend: RuntimeBackend, parameters: [String: Any]?) async throws {
    }
}

@MainActor
protocol ChatRuntimeManaging: AnyObject {
    var state: RuntimeManager.RuntimeState { get }
    func initialize() async throws
    func estimatedModelSize(modelId: String) -> Double
    func isModelDownloadedOffMain(model: DownloadableModel) async -> Bool
}

@MainActor
protocol ChatWebSearching: AnyObject {
    func searchContext(for query: String) async throws -> String?
}

enum ChatGeneratedAssetKind: Equatable {
    case image
    case audio
}

struct ChatMediaToolExecutionPlan {
    let functionName: String
    let toolName: String
    let status: String
    let icon: String
    let details: [ToolCallDetail]
    let model: DownloadableModel
    let request: ExecutionRequest
    let preflightErrorMessage: String?
    let loadingStatus: String
    let operationName: String
    let unavailablePrefix: String
    let noOutputMessage: String
    let completionHint: String
    let attachmentKind: ChatGeneratedAssetKind

    init(
        functionName: String,
        toolName: String,
        status: String,
        icon: String,
        details: [ToolCallDetail],
        model: DownloadableModel,
        request: ExecutionRequest,
        preflightErrorMessage: String? = nil,
        loadingStatus: String,
        operationName: String,
        unavailablePrefix: String,
        noOutputMessage: String,
        completionHint: String,
        attachmentKind: ChatGeneratedAssetKind
    ) {
        self.functionName = functionName
        self.toolName = toolName
        self.status = status
        self.icon = icon
        self.details = details
        self.model = model
        self.request = request
        self.preflightErrorMessage = preflightErrorMessage
        self.loadingStatus = loadingStatus
        self.operationName = operationName
        self.unavailablePrefix = unavailablePrefix
        self.noOutputMessage = noOutputMessage
        self.completionHint = completionHint
        self.attachmentKind = attachmentKind
    }
}

enum ChatToolExecutionUpdate: Equatable {
    case progress(String)
    case modelLoadProgress(ModelLoadProgress)
    case generationProgress(GenerationProgress)
    case generatedAsset(URL, kind: ChatGeneratedAssetKind)
}

enum ChatToolExecutionOutcome: Equatable {
    case toolMessage(String, metrics: GenerationPerformanceMetrics? = nil)
    case failedToolMessage(String, localEngineErrorMessage: String, metrics: GenerationPerformanceMetrics? = nil)
    case downloadRequired(DownloadableModel)
    case cancelled
}

enum ChatToolCallExecutionResult: Equatable {
    case nonTerminal
    case terminalMedia
    case blockedTerminalMedia
}

enum PendingEngineDownloadReason {
    case generation
    case preflight
}

@MainActor
protocol ChatToolExecutionServicing: AnyObject {
    func executeWebSearch(query: String) async -> String
    func executeMediaTool(
        plan: ChatMediaToolExecutionPlan,
        onUpdate: @escaping @MainActor (ChatToolExecutionUpdate) -> Void
    ) async -> ChatToolExecutionOutcome
}

extension VLMExecutor: ChatModelExecuting {}

extension RuntimeManager: ChatRuntimeManaging {
    func isModelDownloadedOffMain(model: DownloadableModel) async -> Bool {
        let checkpointsPath = checkpointsPath
        return await Task.detached(priority: .utility) {
            RuntimeManager.modelStorageStatus(model: model, checkpointsPath: checkpointsPath).isDownloaded
        }.value
    }
}

extension MCPWebSearchService: ChatWebSearching {}
