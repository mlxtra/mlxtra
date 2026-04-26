import XCTest
@testable import MLXHub

@MainActor
final class ChatToolExecutionServiceTests: XCTestCase {
    func testExecuteWebSearchReturnsContext() async {
        let executor = MockChatModelExecutor()
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [])
        let webSearch = MockChatWebSearchService(result: .success("search context"))
        let service = DefaultChatToolExecutionService(
            modelExecutor: executor,
            runtimeManager: runtimeManager,
            webSearchService: webSearch
        )

        let result = await service.executeWebSearch(query: "swift")

        XCTAssertEqual(result, "search context")
        XCTAssertEqual(webSearch.queries, ["swift"])
    }

    func testExecuteMediaToolReturnsDownloadRequiredWhenModelMissing() async {
        let executor = MockChatModelExecutor()
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [])
        let webSearch = MockChatWebSearchService(result: .success(nil))
        let service = DefaultChatToolExecutionService(
            modelExecutor: executor,
            runtimeManager: runtimeManager,
            webSearchService: webSearch
        )
        let model = DownloadableModel(
            id: "missing",
            name: "Missing Model",
            subtitle: "Image generation model",
            modelId: "missing",
            modality: .image,
            downloadSizeGB: 1.0
        )

        let outcome = await service.executeMediaTool(plan: makePlan(model: model)) { _ in }

        XCTAssertEqual(outcome, .downloadRequired(model))
        XCTAssertEqual(executor.receivedRequests.count, 0)
    }

    func testExecuteMediaToolPublishesProgressAndAssetAndReturnsSummary() async {
        let assetURL = URL(fileURLWithPath: "/tmp/generated.png")
        let executor = MockChatModelExecutor(events: [
            .progress("warming up"),
            .image(assetURL),
            .complete("Generated image.", usage: TokenUsage(promptTokens: 1, completionTokens: 2))
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: ["image-model"])
        let webSearch = MockChatWebSearchService(result: .success(nil))
        let service = DefaultChatToolExecutionService(
            modelExecutor: executor,
            runtimeManager: runtimeManager,
            webSearchService: webSearch
        )
        var updates: [ChatToolExecutionUpdate] = []

        let outcome = await service.executeMediaTool(plan: makePlan()) { update in
            updates.append(update)
        }

        XCTAssertEqual(
            updates,
            [
                .progress("warming up"),
                .generatedAsset(assetURL, kind: .image)
            ]
        )
        XCTAssertEqual(
            outcome,
            .toolMessage("Generated image.\nThe generated image is already displayed in the app UI.")
        )
        XCTAssertEqual(executor.receivedRequests.count, 1)
        XCTAssertEqual(executor.receivedRequests[0].modelId, "image-model")
    }

    func testInjectedPersistenceRestoresChatsAndNormalizesStreamingMessages() {
        let selectedChat = Chat(
            title: "Injected chat",
            messages: [
                Message(
                    content: "partial",
                    isUser: false,
                    timestamp: Date(),
                    isStreaming: true
                )
            ],
            timestamp: Date(),
            icon: "message"
        )
        let persistence = MockChatPersistenceService(
            chatsToLoad: [selectedChat],
            selectedChatIdToLoad: selectedChat.id
        )
        let executor = MockChatModelExecutor()
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [])
        let toolExecutor = MockChatToolExecutionService()

        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor
        )

        XCTAssertEqual(viewModel.selectedChatId, selectedChat.id)
        XCTAssertEqual(viewModel.chats.count, 1)
        XCTAssertFalse(viewModel.chats[0].messages[0].isStreaming)
        XCTAssertTrue(executor.delegate === viewModel)
    }

    func testSendMessageBuildsImageGenerationRequestThroughInjectedExecutor() async {
        let assetURL = URL(fileURLWithPath: "/tmp/generated.png")
        let executor = MockChatModelExecutor(events: [
            .image(assetURL),
            .complete("Generated image.", usage: TokenUsage(promptTokens: 0, completionTokens: 0))
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: ["black-forest-labs/FLUX.2-klein-4B"])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.selectTool(.image)
        viewModel.inputText = "Draw a quiet studio desk"

        viewModel.sendMessage()
        await waitUntil { executor.receivedRequests.count == 1 }
        await waitUntil { viewModel.chats.first?.messages.last?.isStreaming == false }

        XCTAssertEqual(executor.receivedRequests.count, 1)
        XCTAssertEqual(executor.receivedRequests[0].backend, .image)
        XCTAssertEqual(executor.receivedRequests[0].modelId, "black-forest-labs/FLUX.2-klein-4B")
        XCTAssertEqual(executor.receivedRequests[0].messages.first?.content, "Draw a quiet studio desk")
        XCTAssertEqual(viewModel.chats.first?.messages.last?.imageURLs, [assetURL])
        XCTAssertFalse(viewModel.chats.first?.messages.last?.isStreaming ?? true)
    }

    func testStreamErrorReplacesStreamingAssistantMessage() async {
        let executor = MockChatModelExecutor(events: [
            .error(ExecutionError.pythonError("bridge failed"))
        ])
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [AIModel.defaultForCurrentHardware.modelId])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.inputText = "Hello"

        viewModel.sendMessage()
        await waitUntil { executor.receivedRequests.count == 1 }
        await waitUntil { (viewModel.chats.first?.messages ?? []).count == 2 }

        let messages = viewModel.chats.first?.messages ?? []
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].isUser)
        XCTAssertFalse(messages[1].isUser)
        XCTAssertFalse(messages[1].isStreaming)
        XCTAssertTrue(messages[1].content.contains("bridge failed"))
        XCTAssertEqual(viewModel.localEngineStatus.state, .needsAttention)
        XCTAssertEqual(viewModel.localEngineStatus.primaryAction, .restart)
    }

    func testFreeLocalEngineMemoryTerminatesExecutorAndUpdatesStatus() async {
        let executor = MockChatModelExecutor()
        executor.isReady = true
        executor.isModelLoaded = true
        executor.currentModelId = AIModel.defaultForCurrentHardware.modelId
        executor.currentModelBackend = .vlm
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )

        XCTAssertTrue(viewModel.canFreeLocalEngineMemory)

        viewModel.freeLocalEngineMemory()
        await waitUntil { executor.terminateCount == 1 }

        XCTAssertEqual(viewModel.localEngineStatus.state, .memoryFreed)
        XCTAssertEqual(viewModel.localEngineStatus.title, "Memory freed")
        XCTAssertFalse(viewModel.canFreeLocalEngineMemory)
    }

    func testMissingModelStatusPersistsAfterSettingsTriggerIsCleared() async {
        let executor = MockChatModelExecutor()
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.selectTool(.image)
        viewModel.inputText = "Draw a quiet studio desk"

        viewModel.sendMessage()
        await waitUntil { viewModel.modelDownloadRequest != nil }

        XCTAssertEqual(viewModel.localEngineStatus.state, .needsDownload)

        viewModel.clearModelDownloadRequest()

        XCTAssertNil(viewModel.modelDownloadRequest)
        XCTAssertEqual(viewModel.localEngineStatus.state, .needsDownload)
        XCTAssertEqual(viewModel.localEngineStatus.primaryAction, .openModels)
    }

    func testMissingModelStatusClearsAfterDownloadRefresh() async {
        let executor = MockChatModelExecutor()
        let imageModelId = "black-forest-labs/FLUX.2-klein-4B"
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )
        viewModel.selectTool(.image)
        viewModel.inputText = "Draw a quiet studio desk"
        viewModel.sendMessage()
        await waitUntil { viewModel.localEngineStatus.state == .needsDownload }

        runtimeManager.downloadedModelIds.insert(imageModelId)
        viewModel.refreshLocalEngineDownloadStatus()
        await waitUntil { viewModel.localEngineStatus.state != .needsDownload }

        XCTAssertNil(viewModel.pendingEngineDownloadModel)
    }

    func testReadyStatusUsesExecutorLoadedModelInsteadOfSelectedModel() {
        let executor = MockChatModelExecutor()
        executor.isReady = true
        executor.isModelLoaded = true
        executor.currentModelId = "ACE-Step/acestep-v15-turbo-continuous"
        executor.currentModelBackend = .music
        let runtimeManager = MockChatRuntimeManager(downloadedModelIds: [])
        let persistence = MockChatPersistenceService(chatsToLoad: [], selectedChatIdToLoad: nil)
        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: MockChatToolExecutionService()
        )

        XCTAssertEqual(viewModel.localEngineStatus.title, "Music model is ready")
        XCTAssertEqual(viewModel.localEngineStatus.detail, "ACE-Step 1.5 Turbo is using memory locally.")
    }

    private func makePlan(model: DownloadableModel? = nil) -> ChatMediaToolExecutionPlan {
        let resolvedModel = model ?? DownloadableModel(
            id: "image-model",
            name: "Image Model",
            subtitle: "Image generation model",
            modelId: "image-model",
            modality: .image,
            downloadSizeGB: 1.0
        )

        return ChatMediaToolExecutionPlan(
            functionName: "generate_image",
            toolName: "Image generation",
            status: "Draw a cat",
            icon: "photo",
            details: [],
            model: resolvedModel,
            request: ExecutionRequest(
                backend: .image,
                modelId: resolvedModel.modelId,
                messages: [ExecutionMessage(role: .user, content: "Draw a cat")],
                outputDirectory: URL(fileURLWithPath: "/tmp"),
                maxTokens: 0,
                temperature: 1.0
            ),
            loadingStatus: "Generating image...",
            operationName: "Image generation",
            unavailablePrefix: "Image generation unavailable",
            noOutputMessage: "Image generation finished without returning an image.",
            completionHint: "The generated image is already displayed in the app UI.",
            attachmentKind: .image
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

@MainActor
private final class MockChatModelExecutor: ChatModelExecuting {
    let backend: RuntimeBackend = .vlm
    var isReady: Bool = true
    var isModelLoaded: Bool = false
    var currentModelId: String?
    var currentModelBackend: RuntimeBackend?
    weak var delegate: VLMExecutionDelegate?
    private let events: [ExecutionEvent]
    private(set) var receivedRequests: [ExecutionRequest] = []
    private(set) var terminateCount = 0

    init(events: [ExecutionEvent] = []) {
        self.events = events
    }

    func initialize() async throws {}

    func execute(request: ExecutionRequest) async throws -> AsyncStream<ExecutionEvent> {
        receivedRequests.append(request)
        currentModelId = request.modelId
        currentModelBackend = request.backend
        isModelLoaded = true
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func terminate() async {
        terminateCount += 1
        isReady = false
        isModelLoaded = false
        currentModelId = nil
        currentModelBackend = nil
    }
}

@MainActor
private final class MockChatRuntimeManager: ChatRuntimeManaging {
    var state: RuntimeManager.RuntimeState = .ready
    var downloadedModelIds: Set<String>

    init(downloadedModelIds: Set<String>) {
        self.downloadedModelIds = downloadedModelIds
    }

    func initialize() async throws {}

    func estimatedModelSize(modelId: String) -> Double {
        1.0
    }

    func isModelDownloadedOffMain(modelId: String) async -> Bool {
        downloadedModelIds.contains(modelId)
    }
}

@MainActor
private final class MockChatWebSearchService: ChatWebSearching {
    var queries: [String] = []
    private let result: Result<String?, Error>

    init(result: Result<String?, Error>) {
        self.result = result
    }

    func searchContext(for query: String) async throws -> String? {
        queries.append(query)
        return try result.get()
    }
}

@MainActor
private final class MockChatPersistenceService: ChatPersistenceServicing {
    private let chatsToLoad: [Chat]
    private let selectedChatIdToLoad: UUID?
    private(set) var savedChats: [Chat] = []
    private(set) var savedSelectedChatId: UUID?

    init(chatsToLoad: [Chat], selectedChatIdToLoad: UUID?) {
        self.chatsToLoad = chatsToLoad
        self.selectedChatIdToLoad = selectedChatIdToLoad
    }

    func loadChats() -> [Chat] {
        chatsToLoad
    }

    func saveChats(_ chats: [Chat]) {
        savedChats = chats
    }

    func loadSelectedChatId() -> UUID? {
        selectedChatIdToLoad
    }

    func saveSelectedChatId(_ selectedChatId: UUID?) {
        savedSelectedChatId = selectedChatId
    }

    func persistAttachments(_ urls: [URL], chatId: UUID, messageId: UUID) -> [URL] {
        urls
    }

    func deleteAttachments(for chatId: UUID) {}
}

@MainActor
private final class MockChatToolExecutionService: ChatToolExecutionServicing {
    func executeWebSearch(query: String) async -> String {
        "unused"
    }

    func executeMediaTool(
        plan: ChatMediaToolExecutionPlan,
        onUpdate: @escaping @MainActor (ChatToolExecutionUpdate) -> Void
    ) async -> ChatToolExecutionOutcome {
        .toolMessage("unused")
    }
}
