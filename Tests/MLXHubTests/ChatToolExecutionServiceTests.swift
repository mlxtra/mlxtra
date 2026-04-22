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
}

@MainActor
private final class MockChatModelExecutor: ChatModelExecuting {
    let backend: RuntimeBackend = .vlm
    var isReady: Bool = true
    var isModelLoaded: Bool = true
    weak var delegate: VLMExecutionDelegate?
    private let events: [ExecutionEvent]
    private(set) var receivedRequests: [ExecutionRequest] = []

    init(events: [ExecutionEvent] = []) {
        self.events = events
    }

    func initialize() async throws {}

    func execute(request: ExecutionRequest) async throws -> AsyncStream<ExecutionEvent> {
        receivedRequests.append(request)
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func terminate() async {}
}

@MainActor
private final class MockChatRuntimeManager: ChatRuntimeManaging {
    var state: RuntimeManager.RuntimeState = .ready
    private let downloadedModelIds: Set<String>

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

    init(chatsToLoad: [Chat], selectedChatIdToLoad: UUID?) {
        self.chatsToLoad = chatsToLoad
        self.selectedChatIdToLoad = selectedChatIdToLoad
    }

    func loadChats() -> [Chat] {
        chatsToLoad
    }

    func saveChats(_ chats: [Chat]) {}

    func loadSelectedChatId() -> UUID? {
        selectedChatIdToLoad
    }

    func saveSelectedChatId(_ selectedChatId: UUID?) {}

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
