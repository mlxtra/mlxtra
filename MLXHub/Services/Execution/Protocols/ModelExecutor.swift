import Foundation

/// Protocol for model executors (VLM, LLM, Audio, Image, etc.)
@MainActor
protocol ModelExecutor: AnyObject {
    var backend: RuntimeBackend { get }
    var isReady: Bool { get }
    
    func initialize() async throws
    func execute(request: ExecutionRequest) async throws -> AsyncStream<ExecutionEvent>
    func terminate() async
}

/// Request for model execution
struct ExecutionRequest {
    let backend: RuntimeBackend
    let modelId: String
    let messages: [ExecutionMessage]
    let images: [URL]?
    let outputDirectory: URL?
    let maxTokens: Int
    let temperature: Double
    let topP: Double?
    let topK: Int?
    let minP: Double?
    let repetitionPenalty: Double?
    let chatTemplateKwargs: [String: Any]?

    init(
        backend: RuntimeBackend = .vlm,
        modelId: String,
        messages: [ExecutionMessage],
        images: [URL]? = nil,
        outputDirectory: URL? = nil,
        maxTokens: Int = 32768,
        temperature: Double = 0.7,
        topP: Double? = nil,
        topK: Int? = nil,
        minP: Double? = nil,
        repetitionPenalty: Double? = nil,
        chatTemplateKwargs: [String: Any]? = nil
    ) {
        self.backend = backend
        self.modelId = modelId
        self.messages = messages
        self.images = images
        self.outputDirectory = outputDirectory
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.chatTemplateKwargs = chatTemplateKwargs
    }
}

/// Single message in conversation
struct ExecutionMessage {
    let role: MessageRole
    let content: String
    
    init(role: MessageRole, content: String) {
        self.role = role
        self.content = content
    }
    
    func toDictionary() -> [String: String] {
        return ["role": role.rawValue, "content": content]
    }
}

enum MessageRole: String {
    case system = "system"
    case user = "user"
    case assistant = "assistant"
}

/// Events streamed during execution
enum ExecutionEvent {
    case started
    case token(String)
    case image(URL)
    case complete(String, usage: TokenUsage)
    case error(Error)
    case progress(String) // For loading/downloading messages
}

/// Token usage statistics
struct TokenUsage {
    let promptTokens: Int
    let completionTokens: Int
    
    var totalTokens: Int { promptTokens + completionTokens }
}

/// Runtime backend types
enum RuntimeBackend: String, Codable, CaseIterable {
    case vlm = "vlm"           // mlx-vlm (Vision Language Model)
    case llm = "llm"           // mlx-lm (Text-only LLM)
    case audio = "audio"       // mlx-audio (TTS/STT)
    case image = "image"       // mflux (Image generation)
    
    var displayName: String {
        switch self {
        case .vlm: return "Vision Language Model"
        case .llm: return "Text Language Model"
        case .audio: return "Audio Processing"
        case .image: return "Image Generation"
        }
    }
}

/// Execution errors
enum ExecutionError: Error {
    case notInitialized
    case processNotRunning
    case modelNotLoaded
    case timeout
    case invalidResponse
    case processCrashed(retryCount: Int)
    case encodingFailed
    case decodingFailed
    case requiresManualRetry(Error)
    case pythonError(String)

    var localizedDescription: String {
        switch self {
        case .notInitialized:
            return "Executor not initialized"
        case .processNotRunning:
            return "Python process not running"
        case .modelNotLoaded:
            return "Model not loaded"
        case .timeout:
            return "Operation timed out"
        case .invalidResponse:
            return "Invalid response from Python"
        case .processCrashed(let count):
            return "Python process crashed (retry \(count))"
        case .encodingFailed:
            return "Failed to encode request"
        case .decodingFailed:
            return "Failed to decode response"
        case .requiresManualRetry:
            return "Requires manual retry"
        case .pythonError(let message):
            return "Python error: \(message)"
        }
    }
}
