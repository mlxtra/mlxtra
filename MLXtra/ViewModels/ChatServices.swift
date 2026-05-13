@preconcurrency import Foundation

@MainActor
protocol ChatPersistenceServicing: AnyObject {
    func loadChats() -> [Chat]
    func saveChats(_ chats: [Chat])
    func scheduleSave(_ chats: [Chat], selectedChatId: UUID?)
    func flushPendingSave()
    func loadSelectedChatId() -> UUID?
    func saveSelectedChatId(_ selectedChatId: UUID?)
    func persistAttachments(_ urls: [URL], chatId: UUID, messageId: UUID) -> [URL]
    func deleteAttachments(for chatId: UUID)
}

extension ChatPersistenceServicing {
    func scheduleSave(_ chats: [Chat], selectedChatId: UUID?) {
        saveChats(chats)
        if let id = selectedChatId { saveSelectedChatId(id) }
    }

    func flushPendingSave() {}
}

@MainActor
protocol ChatModelExecuting: ModelExecutor {
    var isModelLoaded: Bool { get }
    var currentModelId: String? { get }
    var currentModelBackend: RuntimeBackend? { get }
    var delegate: VLMExecutionDelegate? { get set }
}

@MainActor
protocol ChatRuntimeManaging: AnyObject {
    var state: RuntimeManager.RuntimeState { get }
    func initialize() async throws
    func estimatedModelSize(modelId: String) -> Double
    func isModelDownloadedOffMain(modelId: String) async -> Bool
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
    let loadingStatus: String
    let operationName: String
    let unavailablePrefix: String
    let noOutputMessage: String
    let completionHint: String
    let attachmentKind: ChatGeneratedAssetKind
}

enum ChatToolExecutionUpdate: Equatable {
    case progress(String)
    case modelLoadProgress(ModelLoadProgress)
    case generatedAsset(URL, kind: ChatGeneratedAssetKind)
}

enum ChatToolExecutionOutcome: Equatable {
    case toolMessage(String, metrics: GenerationPerformanceMetrics? = nil)
    case downloadRequired(DownloadableModel)
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

@MainActor
final class LocalChatPersistenceService: ChatPersistenceServicing {
    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let selectedChatKey: String
    private let storageDirectory: URL
    private let writeQueue = DispatchQueue(label: "com.localstudio.mlxtra.chat-persistence", qos: .utility)
    private var pendingSaveWorkItem: DispatchWorkItem?
    private var pendingSaveSnapshot: (chats: [Chat], selectedChatId: UUID?)?
    private let saveDebounceInterval: TimeInterval = 1.0

    init(
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        storageDirectory: URL? = nil,
        selectedChatKey: String = "MLXtra.selectedChatId"
    ) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.selectedChatKey = selectedChatKey
        self.storageDirectory = storageDirectory ?? (
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser
        )
        .appendingPathComponent("MLXtra", isDirectory: true)
    }

    deinit {
        pendingSaveWorkItem?.cancel()
        if let snapshot = pendingSaveSnapshot {
            do {
                try FileManager.default.createDirectory(
                    at: storageDirectory,
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot.chats)
                let conversationsURL = storageDirectory.appendingPathComponent("conversations.json")
                try data.write(to: conversationsURL, options: [.atomic])
                MainActor.assumeIsolated {
                    if let selectedChatId = snapshot.selectedChatId {
                        userDefaults.set(selectedChatId.uuidString, forKey: selectedChatKey)
                    } else {
                        userDefaults.removeObject(forKey: selectedChatKey)
                    }
                }
            } catch {
                print("Failed to save pending conversation history: \(error)")
            }
        }
        // Use async to avoid deadlock if deinit is called from within the write queue
        writeQueue.async {}
    }

    private var conversationsURL: URL {
        storageDirectory.appendingPathComponent("conversations.json")
    }

    private var attachmentsDirectory: URL {
        storageDirectory.appendingPathComponent("Attachments", isDirectory: true)
    }

    func loadChats() -> [Chat] {
        flushPendingWrites()

        guard fileManager.fileExists(atPath: conversationsURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: conversationsURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Chat].self, from: data)
        } catch {
            print("Failed to load conversation history: \(error)")
            return []
        }
    }

    func saveChats(_ chats: [Chat]) {
        let storageDirectory = storageDirectory
        let conversationsURL = conversationsURL

        writeQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: storageDirectory,
                    withIntermediateDirectories: true
                )

                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601

                let data = try encoder.encode(chats)
                try data.write(to: conversationsURL, options: [.atomic])
            } catch {
                print("Failed to save conversation history: \(error)")
            }
        }
    }

    func scheduleSave(_ chats: [Chat], selectedChatId: UUID?) {
        pendingSaveWorkItem?.cancel()
        pendingSaveSnapshot = (chats, selectedChatId)
        let workItem = DispatchWorkItem { [weak self] in
            self?.writePendingSaveSnapshot()
        }
        pendingSaveWorkItem = workItem
        writeQueue.asyncAfter(deadline: .now() + saveDebounceInterval, execute: workItem)
    }

    func flushPendingSave() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        writePendingSaveSnapshot()
    }

    private func writePendingSaveSnapshot() {
        guard let snapshot = pendingSaveSnapshot else { return }
        pendingSaveSnapshot = nil
        saveChats(snapshot.chats)
        if let id = snapshot.selectedChatId {
            saveSelectedChatId(id)
        }
    }

    private func flushPendingWrites() {
        // Also flush any pending debounced save before sync-waiting.
        flushPendingSave()
        writeQueue.sync {}
    }

    func loadSelectedChatId() -> UUID? {
        guard let storedValue = userDefaults.string(forKey: selectedChatKey) else {
            return nil
        }

        return UUID(uuidString: storedValue)
    }

    func saveSelectedChatId(_ selectedChatId: UUID?) {
        if let selectedChatId {
            userDefaults.set(selectedChatId.uuidString, forKey: selectedChatKey)
        } else {
            userDefaults.removeObject(forKey: selectedChatKey)
        }
    }

    func persistAttachments(_ urls: [URL], chatId: UUID, messageId: UUID) -> [URL] {
        guard !urls.isEmpty else { return [] }

        let messageAttachmentsDirectory = attachmentsDirectory
            .appendingPathComponent(chatId.uuidString, isDirectory: true)
            .appendingPathComponent(messageId.uuidString, isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: messageAttachmentsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            print("Failed to create attachment directory: \(error)")
            return urls
        }

        return urls.enumerated().map { index, sourceURL in
            let destinationURL = messageAttachmentsDirectory
                .appendingPathComponent("\(index)-\(sourceURL.lastPathComponent)")

            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }

                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                return destinationURL
            } catch {
                print("Failed to copy attachment \(sourceURL.path): \(error)")
                return sourceURL
            }
        }
    }

    func deleteAttachments(for chatId: UUID) {
        let chatAttachmentsDirectory = attachmentsDirectory
            .appendingPathComponent(chatId.uuidString, isDirectory: true)

        guard fileManager.fileExists(atPath: chatAttachmentsDirectory.path) else { return }

        do {
            try fileManager.removeItem(at: chatAttachmentsDirectory)
        } catch {
            print("Failed to delete attachments for chat \(chatId): \(error)")
        }
    }
}

@MainActor
final class DefaultChatToolExecutionService: ChatToolExecutionServicing {
    private let modelExecutor: ChatModelExecuting
    private let runtimeManager: ChatRuntimeManaging
    private let webSearchService: ChatWebSearching

    init(
        modelExecutor: ChatModelExecuting,
        runtimeManager: ChatRuntimeManaging,
        webSearchService: ChatWebSearching
    ) {
        self.modelExecutor = modelExecutor
        self.runtimeManager = runtimeManager
        self.webSearchService = webSearchService
    }

    func executeWebSearch(query: String) async -> String {
        do {
            guard let context = try await webSearchService.searchContext(for: query) else {
                return "No results found."
            }

            return context
        } catch {
            return "Web search unavailable: \(error.localizedDescription)"
        }
    }

    func executeMediaTool(
        plan: ChatMediaToolExecutionPlan,
        onUpdate: @escaping @MainActor (ChatToolExecutionUpdate) -> Void
    ) async -> ChatToolExecutionOutcome {
        guard await runtimeManager.isModelDownloadedOffMain(modelId: plan.model.modelId) else {
            return .downloadRequired(plan.model)
        }

        do {
            let startedAt = Date()
            var firstOutputAt: Date?
            var observedTokenEvents = 0
            var completionTokenCount = 0
            var backendTokensPerSecond: Double?
            let stream = try await modelExecutor.execute(request: plan.request)
            var generatedAssetURL: URL?
            var generationSummary = "\(plan.operationName) completed."

            for await event in stream {
                if Task.isCancelled {
                    break
                }

                switch event {
                case .progress(let message):
                    onUpdate(.progress(message))
                case .modelLoadProgress(let progress):
                    onUpdate(.modelLoadProgress(progress))
                case .image(let imageURL) where plan.attachmentKind == .image:
                    firstOutputAt = firstOutputAt ?? Date()
                    generatedAssetURL = imageURL
                    onUpdate(.generatedAsset(imageURL, kind: .image))
                case .audio(let audioURL) where plan.attachmentKind == .audio:
                    firstOutputAt = firstOutputAt ?? Date()
                    generatedAssetURL = audioURL
                    onUpdate(.generatedAsset(audioURL, kind: .audio))
                case .token(let token):
                    guard !token.isEmpty else { break }
                    firstOutputAt = firstOutputAt ?? Date()
                    observedTokenEvents += 1
                case .complete(let response, let usage):
                    if !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        generationSummary = response
                    }
                    completionTokenCount = usage.completionTokens
                    backendTokensPerSecond = usage.tokensPerSecond
                case .error(let error):
                    throw error
                case .started, .toolCalls, .image, .audio:
                    break
                }
            }

            let metrics = GenerationPerformanceMetrics.measured(
                startedAt: startedAt,
                firstOutputAt: firstOutputAt,
                outputTokenCount: completionTokenCount > 0 ? completionTokenCount : observedTokenEvents,
                backendTokensPerSecond: backendTokensPerSecond
            )

            if generatedAssetURL != nil {
                return .toolMessage("\(generationSummary)\n\(plan.completionHint)", metrics: metrics)
            }

            return .toolMessage(plan.noOutputMessage, metrics: metrics)
        } catch {
            return .toolMessage("\(plan.unavailablePrefix): \(error.localizedDescription)")
        }
    }
}

extension VLMExecutor: ChatModelExecuting {}

extension RuntimeManager: ChatRuntimeManaging {
    func isModelDownloadedOffMain(modelId: String) async -> Bool {
        let checkpointsPath = checkpointsPath
        return await Task.detached(priority: .utility) {
            RuntimeManager.isModelDownloaded(modelId: modelId, checkpointsPath: checkpointsPath)
        }.value
    }
}

extension MCPWebSearchService: ChatWebSearching {}
