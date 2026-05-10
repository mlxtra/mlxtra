#if DEBUG
import AppKit
import Foundation

@MainActor
extension ChatViewModel {
    static func makeUITestViewModel() -> ChatViewModel {
        let suiteName = "MLXHubUITests"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: PromptConfiguration.hasSeenFirstRunGuideKey)

        let persistence = UITestChatPersistenceService()
        let runtimeManager = UITestRuntimeManager()
        let executor = UITestModelExecutor()
        let toolExecutor = DefaultChatToolExecutionService(
            modelExecutor: executor,
            runtimeManager: runtimeManager,
            webSearchService: UITestWebSearchService()
        )

        let viewModel = ChatViewModel(
            chatPersistence: persistence,
            vlmExecutor: executor,
            runtimeManager: runtimeManager,
            toolExecutor: toolExecutor,
            userDefaults: defaults
        )

        if ProcessInfo.processInfo.environment["MLXHUB_UI_TEST_FORCE_MODEL_LOADING_INDICATOR"] == "1" {
            let profile = viewModel.activeModelProfile
            viewModel.isModelLoading = true
            viewModel.loadingMessage = "Loading model weights"
            viewModel.modelLoadProgress = ModelLoadProgress(
                modelId: profile.modelId,
                backend: profile.backend,
                phase: .loadingWeights,
                detail: "Loading model weights"
            )
        }

        return viewModel
    }
}

@MainActor
private final class UITestChatPersistenceService: ChatPersistenceServicing {
    private var chats: [Chat] = []
    private var selectedChatId: UUID?

    func loadChats() -> [Chat] {
        chats
    }

    func saveChats(_ chats: [Chat]) {
        self.chats = chats
    }

    func loadSelectedChatId() -> UUID? {
        selectedChatId
    }

    func saveSelectedChatId(_ selectedChatId: UUID?) {
        self.selectedChatId = selectedChatId
    }

    func persistAttachments(_ urls: [URL], chatId: UUID, messageId: UUID) -> [URL] {
        urls
    }

    func deleteAttachments(for chatId: UUID) {}
}

@MainActor
private final class UITestRuntimeManager: ChatRuntimeManaging {
    var state: RuntimeManager.RuntimeState = .ready

    func initialize() async throws {
        state = .ready
    }

    func estimatedModelSize(modelId: String) -> Double {
        1.0
    }

    func isModelDownloadedOffMain(modelId: String) async -> Bool {
        true
    }
}

@MainActor
private final class UITestModelExecutor: ChatModelExecuting {
    let backend: RuntimeBackend = .vlm
    var isReady: Bool = true
    var isModelLoaded: Bool = false
    var currentModelId: String?
    var currentModelBackend: RuntimeBackend?
    weak var delegate: VLMExecutionDelegate?

    func initialize() async throws {
        isReady = true
    }

    func execute(request: ExecutionRequest) async throws -> AsyncStream<ExecutionEvent> {
        isReady = true
        isModelLoaded = true
        currentModelId = request.modelId
        currentModelBackend = request.backend

        let events = try events(for: request)
        let shouldDelayForLoadingProbe = ProcessInfo.processInfo.environment["MLXHUB_UI_TEST_DELAY_MODEL_LOADING"] == "1" || request.messages.contains {
            $0.role == .user && ($0.content?.localizedCaseInsensitiveContains("ui test loading indicator") ?? false)
        }

        if shouldDelayForLoadingProbe {
            let modelId = request.modelId
            let backend = request.backend
            return AsyncStream { continuation in
                Task { @MainActor in
                    self.delegate?.modelLoadingProgress(
                        ModelLoadProgress(
                            modelId: modelId,
                            backend: backend,
                            phase: .loadingWeights,
                            detail: "Loading model weights"
                        )
                    )
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    for event in events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
            }
        }

        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func terminate() async {
        isReady = false
        isModelLoaded = false
        currentModelId = nil
        currentModelBackend = nil
    }

    private func events(for request: ExecutionRequest) throws -> [ExecutionEvent] {
        switch request.backend {
        case .image:
            let outputURL = try generatedImageURL(in: request.outputDirectory)
            return [
                .started,
                .progress("Generating image..."),
                .image(outputURL),
                .complete("", usage: TokenUsage(promptTokens: 0, completionTokens: 0)),
            ]
        case .audio:
            let outputURL = try generatedAudioURL(
                in: request.outputDirectory,
                filename: "ui-test-generated-speech.wav",
                sampleRate: 24_000
            )
            return [
                .started,
                .progress("Generating speech..."),
                .audio(outputURL),
                .complete("", usage: TokenUsage(promptTokens: 0, completionTokens: 0)),
            ]
        case .music:
            let outputURL = try generatedAudioURL(
                in: request.outputDirectory,
                filename: "ui-test-generated-music.wav",
                sampleRate: 48_000
            )
            return [
                .started,
                .progress("Generating music..."),
                .audio(outputURL),
                .complete("", usage: TokenUsage(promptTokens: 0, completionTokens: 0)),
            ]
        case .vlm, .llm:
            let response = chatResponse(for: request)
            return [
                .started,
                .token(response),
                .complete(response, usage: TokenUsage(promptTokens: 1, completionTokens: response.split(separator: " ").count)),
            ]
        }
    }

    private func chatResponse(for request: ExecutionRequest) -> String {
        let prompt = request.messages.last { $0.role == .user }?.content ?? ""

        if prompt.localizedCaseInsensitiveContains("ui test multi turn first") {
            return "First deterministic turn."
        }

        if prompt.localizedCaseInsensitiveContains("ui test multi turn second") {
            let hasPreviousAssistantTurn = request.messages.contains {
                $0.role == .assistant && ($0.content?.contains("First deterministic turn.") ?? false)
            }
            return hasPreviousAssistantTurn
                ? "Second deterministic turn with prior context."
                : "Second deterministic turn without prior context."
        }

        if prompt.localizedCaseInsensitiveContains("ui test long scroll response") {
            return Self.longScrollResponse
        }

        if prompt.localizedCaseInsensitiveContains("ui test plain rail response") {
            return Self.plainRailResponse
        }

        if prompt.localizedCaseInsensitiveContains("ui test markdown rendering") {
            return Self.markdownResponse
        }

        if prompt.localizedCaseInsensitiveContains("ui test loading indicator") {
            return "UI test delayed loading response."
        }

        if prompt.localizedCaseInsensitiveContains("ui test very long multi-line input") {
            return "Long multi-line input accepted."
        }

        return "UI test chat response"
    }

    private static let longScrollResponse: String = {
        var sections = [
            "# Long Scroll Probe",
            "Long scroll response begins."
        ]

        for index in 1...38 {
            sections.append(
                "Long scroll paragraph \(index): This deterministic paragraph keeps enough rendered text on screen to force the transcript to scroll while the floating composer remains fixed at the bottom."
            )
        }

        sections.append("Long scroll response ends.")
        return sections.joined(separator: "\n\n")
    }()

    private static let plainRailResponse: String = {
        let sentence = "Plain rail response keeps a native text view constrained to the same visual rail as the composer input field while wrapping a long assistant message."
        return "Plain rail response begins. " + Array(repeating: sentence, count: 10).joined(separator: " ")
    }()

    private static let markdownResponse = """
    # Markdown Rendering Probe

    This response includes **bold text**, `inline code`, and a compact list.

    - First rendered bullet
    - Second rendered bullet

    ```swift
    let value = "rendered"
    print(value)
    ```

    | Key | Value |
    | --- | --- |
    | Status | Rendered |
    """

    private func generatedImageURL(in directory: URL?) throws -> URL {
        let directory = try resolvedOutputDirectory(directory)
        let outputURL = directory.appendingPathComponent("ui-test-generated-image.png")
        try UITestAssetWriter.writePNG(to: outputURL)
        return outputURL
    }

    private func generatedAudioURL(
        in directory: URL?,
        filename: String,
        sampleRate: Int
    ) throws -> URL {
        let directory = try resolvedOutputDirectory(directory)
        let outputURL = directory.appendingPathComponent(filename)
        try UITestAssetWriter.writeWAV(to: outputURL, sampleRate: sampleRate)
        return outputURL
    }

    private func resolvedOutputDirectory(_ directory: URL?) throws -> URL {
        let outputDirectory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXHubUITests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        return outputDirectory
    }
}

@MainActor
private final class UITestWebSearchService: ChatWebSearching {
    func searchContext(for query: String) async throws -> String? {
        "UI test search result for \(query)"
    }
}

private enum UITestAssetWriter {
    private enum AssetError: Error {
        case imageAllocationFailed
        case imageEncodingFailed
    }

    static func writePNG(to url: URL) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 64,
            pixelsHigh: 64,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw AssetError.imageAllocationFailed
        }

        for y in 0..<64 {
            for x in 0..<64 {
                let color = NSColor(
                    calibratedRed: CGFloat(x) / 63.0,
                    green: CGFloat(y) / 63.0,
                    blue: 0.72,
                    alpha: 1.0
                )
                bitmap.setColor(color, atX: x, y: y)
            }
        }

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw AssetError.imageEncodingFailed
        }
        try data.write(to: url, options: [.atomic])
    }

    static func writeWAV(to url: URL, sampleRate: Int, duration: Double = 1.0) throws {
        let channels = 1
        let bitsPerSample = 16
        let frameCount = max(Int(Double(sampleRate) * duration), 1)
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = frameCount * blockAlign

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        appendUInt32(UInt32(36 + dataSize), to: &data)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(UInt16(channels), to: &data)
        appendUInt32(UInt32(sampleRate), to: &data)
        appendUInt32(UInt32(byteRate), to: &data)
        appendUInt16(UInt16(blockAlign), to: &data)
        appendUInt16(UInt16(bitsPerSample), to: &data)
        data.append("data".data(using: .ascii)!)
        appendUInt32(UInt32(dataSize), to: &data)

        for frame in 0..<frameCount {
            let time = Double(frame) / Double(sampleRate)
            let value = Int16(sin(2.0 * Double.pi * 440.0 * time) * 10_000)
            appendInt16(value, to: &data)
        }

        try data.write(to: url, options: [.atomic])
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func appendInt16(_ value: Int16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
#endif
