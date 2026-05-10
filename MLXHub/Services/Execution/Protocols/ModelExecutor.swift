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

struct ExecutionRequest {
    let requestID: String
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
    let tools: [[String: Any]]?
    let parameters: [String: Any]?

    init(
        requestID: String = UUID().uuidString,
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
        chatTemplateKwargs: [String: Any]? = nil,
        tools: [[String: Any]]? = nil,
        parameters: [String: Any]? = nil
    ) {
        self.requestID = requestID
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
        self.tools = tools
        self.parameters = parameters
    }
}

struct ExecutionToolCallFunction {
    let name: String
    let arguments: String

    func toDictionary() -> [String: Any] {
        ["name": name, "arguments": arguments]
    }
}

struct ExecutionToolCall {
    let id: String
    let function: ExecutionToolCallFunction

    func toDictionary() -> [String: Any] {
        ["id": id, "type": "function", "function": function.toDictionary()]
    }
}

struct ExecutionMessage {
    let role: MessageRole
    let content: String?
    let toolCalls: [ExecutionToolCall]?
    let toolCallId: String?
    let name: String?

    init(role: MessageRole, content: String? = nil, toolCalls: [ExecutionToolCall]? = nil, toolCallId: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = ["role": role.rawValue]
        if let content { dict["content"] = content }
        if let toolCalls { dict["tool_calls"] = toolCalls.map { $0.toDictionary() } }
        if let toolCallId { dict["tool_call_id"] = toolCallId }
        if let name { dict["name"] = name }
        return dict
    }
}

enum MessageRole: String {
    case system = "system"
    case user = "user"
    case assistant = "assistant"
    case tool = "tool"
}

enum ExecutionEvent {
    case started
    case token(String)
    case image(URL)
    case audio(URL)
    case complete(String, usage: TokenUsage)
    case toolCalls([ExecutionToolCall])
    case error(Error)
    case progress(String)
    case modelLoadProgress(ModelLoadProgress)
}

/// Token usage statistics
struct TokenUsage {
    let promptTokens: Int
    let completionTokens: Int
    let promptTokensPerSecond: Double?
    let generationTokensPerSecond: Double?
    let peakMemoryGB: Double?

    init(
        promptTokens: Int,
        completionTokens: Int,
        promptTokensPerSecond: Double? = nil,
        generationTokensPerSecond: Double? = nil,
        peakMemoryGB: Double? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.promptTokensPerSecond = promptTokensPerSecond
        self.generationTokensPerSecond = generationTokensPerSecond
        self.peakMemoryGB = peakMemoryGB
    }
    
    var totalTokens: Int { promptTokens + completionTokens }
    var tokensPerSecond: Double? { generationTokensPerSecond }
}

/// Runtime backend types
enum RuntimeBackend: String, Codable, CaseIterable {
    case vlm = "vlm"           // mlx-vlm (Vision Language Model)
    case llm = "llm"           // mlx-lm (Text-only LLM)
    case audio = "audio"       // mlx-audio (TTS/STT)
    case image = "image"       // mflux (Image generation)
    case music = "music"       // ACE-Step (Music generation)
    
    var displayName: String {
        switch self {
        case .vlm: return "Vision Language Model"
        case .llm: return "Text Language Model"
        case .audio: return "Audio Processing"
        case .image: return "Image Generation"
        case .music: return "Music Generation"
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
