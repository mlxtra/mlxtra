import Foundation
import Combine

#if DEBUG
private enum VLMStreamDiagnostics {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MLXHUB_STREAM_DIAGNOSTICS"] == "1"
            || UserDefaults.standard.bool(forKey: "MLXHub.streamDiagnostics")
    }

    static func now() -> TimeInterval {
        Date().timeIntervalSinceReferenceDate
    }

    static func log(_ message: String) {
        guard isEnabled else { return }
        print("[StreamDiag][VLMExecutor] \(String(format: "%.6f", now())) \(message)")
    }
}
#endif

/// Executor for Vision Language Models using mlx-vlm via Python bridge
@MainActor
class VLMExecutor: NSObject, ModelExecutor {
    var backend: RuntimeBackend { .vlm }

    private(set) var isReady: Bool = false
    private(set) var isModelLoaded: Bool = false
    private(set) var currentModelId: String?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var currentRequest: ExecutionRequest?
    private var retryCount: Int = 0
    private let maxRetries: Int = 1

    weak var delegate: VLMExecutionDelegate?

    // MARK: - Initialization

    override init() {
        super.init()
    }

    // MARK: - ModelExecutor Protocol

    func initialize() async throws {
        guard !isReady else { return }
        try await startBridge()
        isReady = true
    }

func execute(request: ExecutionRequest) async throws -> AsyncStream<ExecutionEvent> {
    guard isReady else {
        throw ExecutionError.notInitialized
    }

    // Auto-retry on failure
    do {
        return try await attemptExecute(request: request)
    } catch {
        if shouldRetry(error: error) {
            retryCount += 1
            delegate?.executionWillRetry(attempt: retryCount)
            do {
                try await restartBridge()
            } catch {
                delegate?.executionDidFail(error: error)
                throw error
            }
            return try await attemptExecute(request: request)
        } else {
            delegate?.executionDidFail(error: error)
            throw error
        }
    }
}

func terminate() async {
    stdoutPipe?.fileHandleForReading.readabilityHandler = nil
    stderrPipe?.fileHandleForReading.readabilityHandler = nil

    process?.terminate()
    process?.waitUntilExit()
    process = nil

    stdinPipe?.fileHandleForWriting.closeFile()
    stdoutPipe?.fileHandleForReading.closeFile()
    stderrPipe?.fileHandleForReading.closeFile()
    stdinPipe = nil
    stdoutPipe = nil
    stderrPipe = nil

    isReady = false
    isModelLoaded = false
    currentModelId = nil
    currentRequest = nil
    retryCount = 0
}

    // MARK: - Private Methods

    private func startBridge() async throws {
        let runtimeManager = RuntimeManager()
        try await runtimeManager.initialize()

        let pythonPath = runtimeManager.pythonExecutablePath()
        let bridgePath = runtimeManager.bridgeScriptPath()

        process = Process()
        process?.executableURL = pythonPath
        process?.arguments = [bridgePath.path]

        // Clean environment to avoid conflicts with system Python
        var cleanEnv = ProcessInfo.processInfo.environment
        // Remove Python-related env vars that could cause conflicts
        cleanEnv.removeValue(forKey: "PYTHONPATH")
        cleanEnv.removeValue(forKey: "PYTHONHOME")
        cleanEnv.removeValue(forKey: "VIRTUAL_ENV")
        cleanEnv.removeValue(forKey: "CONDA_PREFIX")
        cleanEnv.removeValue(forKey: "CONDA_DEFAULT_ENV")
        cleanEnv.removeValue(forKey: "PYENV_ROOT")
        cleanEnv.removeValue(forKey: "PYENV_VERSION")

        // Set critical env vars for the bundled Python
        cleanEnv["PYTHONDONTWRITEBYTECODE"] = "1"
        cleanEnv["PYTHONUNBUFFERED"] = "1"
        cleanEnv["HF_HOME"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface").path
        cleanEnv["HF_HUB_CACHE"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub").path
        cleanEnv["ACESTEP_CHECKPOINTS_DIR"] = runtimeManager.checkpointsPath.path

        // Disable Metal validation to prevent crashes with ACE-Step/MLX
        // Metal validation can trigger false positives with certain compute shaders
        cleanEnv["MTL_DEBUG_LAYER"] = "0"
        cleanEnv["MTL_SHADER_VALIDATION"] = "0"

        process?.environment = cleanEnv

        print("[VLMExecutor] Starting Python bridge at \(pythonPath.path)")
        print("[VLMExecutor] Bridge script at \(bridgePath.path)")

        // Setup pipes
        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        stderrPipe = Pipe()

        process?.standardInput = stdinPipe
        process?.standardOutput = stdoutPipe
        process?.standardError = stderrPipe

        // Setup handlers
        setupOutputHandlers()

        // Start process
        try process?.run()

        // Wait for ready signal with timeout
        try await waitForReady(timeout: 10.0)
    }

private func restartBridge() async throws {
    await terminate()
    do {
        try await startBridge()
    } catch {
        isReady = false
        isModelLoaded = false
        currentModelId = nil
        currentRequest = nil
        retryCount = 0
        throw error
    }
}

    private func waitForReady(timeout: TimeInterval) async throws {
        let startTime = Date()
        let readyState = ReadyState()
        let lineBuffer = BridgeLineBuffer()

        stdoutPipe?.fileHandleForReading.readabilityHandler = { [weak readyState] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

for line in lineBuffer.append(output) {
                print("[VLMExecutor] Bridge output: \(line)")

                do {
                    if let lineData = line.data(using: .utf8),
                       let json = try JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                       let type = json["type"] as? String {
                        if type == "system.ready" {
                            print("[VLMExecutor] Bridge is ready")
                            Task { await readyState?.setReady() }
                        } else if type == "error" {
                            let message = json["message"] as? String ?? "Unknown error"
                            print("[VLMExecutor] Bridge initialization error: \(message)")
                        }
                    }
                } catch {
                    // Ignore parse errors but log them
                    print("[VLMExecutor] Parse error: \(error)")
                }
            }
        }

        // Wait with timeout
        while !(await readyState.isReady) {
            if Date().timeIntervalSince(startTime) > timeout {
                print("[VLMExecutor] Timeout waiting for bridge ready signal")
                throw ExecutionError.timeout
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }

/// Thread-safe ready state
private actor ReadyState {
    private(set) var isReady: Bool = false

    func setReady() {
        isReady = true
    }
}

/// Thread-safe model loaded state using a class with lock for sync access from handlers
private class ModelLoadedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _isLoaded: Bool = false
    private var _errorMessage: String? = nil

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isLoaded
    }

    var errorMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return _errorMessage
    }

    func setLoaded() {
        lock.lock()
        defer { lock.unlock() }
        _isLoaded = true
    }

    func setError(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        _errorMessage = message
    }
}

    private func attemptExecute(request: ExecutionRequest) async throws -> AsyncStream<ExecutionEvent> {
        currentRequest = request

        // Load model if needed
        let modelCacheKey = "\(request.backend.rawValue):\(request.modelId)"
        if currentModelId != modelCacheKey {
            try await loadModel(request.modelId, backend: request.backend)
            currentModelId = modelCacheKey
        }

        let messages = request.messages.map { $0.toDictionary() }
        var payload: [String: Any] = [
            "type": messageType(for: request.backend),
            "model": request.modelId,
            "messages": messages,
            "max_tokens": request.maxTokens,
            "temperature": request.temperature,
            "images": request.images?.map { $0.path } ?? []
        ]

        if let outputDirectory = request.outputDirectory {
            payload["output_dir"] = outputDirectory.path
        }

        if let topP = request.topP {
            payload["top_p"] = topP
        }
        if let topK = request.topK {
            payload["top_k"] = topK
        }
        if let minP = request.minP {
            payload["min_p"] = minP
        }
        if let repetitionPenalty = request.repetitionPenalty {
            payload["repetition_penalty"] = repetitionPenalty
        }

        if let chatTemplateKwargs = request.chatTemplateKwargs {
            payload["chat_template_kwargs"] = chatTemplateKwargs
        }

        if let tools = request.tools {
            payload["tools"] = tools
        }

        if let parameters = request.parameters {
            payload["parameters"] = parameters
        }

        // Send request
        try await sendRequest(payload)

        // Return stream
        return AsyncStream { continuation in
            let streamTask = Task {
                await self.processStream(continuation: continuation)
            }

            continuation.onTermination = { _ in
                streamTask.cancel()
            }
        }
    }

private func loadModel(_ modelId: String, backend: RuntimeBackend) async throws {
    delegate?.modelLoadingStarted(modelId: modelId)

    let payload: [String: Any] = [
        "type": "init",
        "model_id": modelId,
        "backend": backend.rawValue
    ]

    try await sendRequest(payload)

    do {
        try await waitForModelLoaded()
        isModelLoaded = true
        delegate?.modelLoadingCompleted(modelId: modelId)
    } catch {
        delegate?.modelLoadingFailed(modelId: modelId, error: error)
        throw error
    }
}

private func waitForModelLoaded() async throws {
    let startTime = Date()
    let timeout: TimeInterval = 300.0 // 5 minutes timeout for model loading
    let loadedState = ModelLoadedState()
    let lineBuffer = BridgeLineBuffer()

    var handlerInstalled = false
let handler: @Sendable (FileHandle) -> Void = { [weak loadedState, weak lineBuffer] handle in
        let data = handle.availableData
        guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

for line in lineBuffer?.append(output) ?? [] {
            print("[VLMExecutor] Model load received: \(line.prefix(200))...")

            do {
                if let lineData = line.data(using: .utf8),
                let json = try JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let type = json["type"] as? String {
                    if type == "model.loaded" || type == "model.initialized" {
                        print("[VLMExecutor] Model load handler: setting loaded (type=\(type))")
                        loadedState?.setLoaded()
                    } else if type == "error" {
                        let message = json["message"] as? String ?? "Unknown error"
                        print("[VLMExecutor] Model loading error: \(message)")
                        loadedState?.setError(message)
                    } else if type == "model.loading", let status = json["status"] as? String {
                        print("[VLMExecutor] Model loading status: \(status)")
                    }
                }
            } catch {
                print("[VLMExecutor] Parse error: \(error)")
            }
        }
    }

    print("[VLMExecutor] waitForModelLoaded: installing handler on stdoutPipe")
    stdoutPipe?.fileHandleForReading.readabilityHandler = handler
    handlerInstalled = true
    print("[VLMExecutor] waitForModelLoaded: handler installed")

    defer {
        if handlerInstalled {
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        }
    }

    while !loadedState.isLoaded {
        if let error = loadedState.errorMessage {
            throw ExecutionError.pythonError("Model loading failed: \(error)")
        }
        if process?.isRunning == false {
            throw ExecutionError.processNotRunning
        }
        if Date().timeIntervalSince(startTime) > timeout {
            print("[VLMExecutor] Timeout waiting for model loaded signal")
            throw ExecutionError.timeout
        }
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
    }
    print("[VLMExecutor] Model load complete, isModelLoaded will be set to true")
}

private func sendRequest(_ payload: [String: Any]) async throws {
    guard stdinPipe != nil else {
        throw ExecutionError.processNotRunning
    }

    let data = try JSONSerialization.data(withJSONObject: payload)
    guard let json = String(data: data, encoding: .utf8) else {
        throw ExecutionError.encodingFailed
    }

    let line = json + "\n"
    guard let lineData = line.data(using: .utf8) else {
        throw ExecutionError.encodingFailed
    }

    do {
        try stdinPipe?.fileHandleForWriting.write(contentsOf: lineData)
    } catch {
        if process?.isRunning == false {
            throw ExecutionError.processNotRunning
        }
        throw ExecutionError.encodingFailed
    }
}

private func processStream(continuation: AsyncStream<ExecutionEvent>.Continuation) async {
    continuation.yield(.started)

    let responseBuilder = ResponseBuilder()
    let lineBuffer = BridgeLineBuffer()

stdoutPipe?.fileHandleForReading.readabilityHandler = { [weak responseBuilder, weak lineBuffer] handle in
        let data = handle.availableData
        guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

        for line in lineBuffer?.append(output) ?? [] {
            // Debug: Log all received lines
#if DEBUG
            if VLMStreamDiagnostics.isEnabled {
                print("[VLMExecutor] Received: \(line.prefix(200))...")
            }
#endif

            do {
                guard let lineData = line.data(using: .utf8),
                    let json = try JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                    let type = json["type"] as? String else {
                    print("[VLMExecutor] Could not parse JSON or missing type field")
                    continue
                }

                switch type {
                case "chat.completion.chunk":
                    if let choices = json["choices"] as? [[String: Any]],
                        let first = choices.first,
                        let delta = first["delta"] as? [String: Any],
                        let content = delta["content"] as? String {
#if DEBUG
                        let yieldStartedAt = VLMStreamDiagnostics.now()
                        VLMStreamDiagnostics.log("chunk.received tokenChars=\(content.count)")
#endif
                        responseBuilder?.append(content)
                        continuation.yield(.token(content))
#if DEBUG
                        let yieldFinishedAt = VLMStreamDiagnostics.now()
                        VLMStreamDiagnostics.log("chunk.yielded tokenChars=\(content.count) elapsedMs=\(String(format: "%.2f", (yieldFinishedAt - yieldStartedAt) * 1000))")
#endif
                    }

                case "chat.completion.complete":
#if DEBUG
                    VLMStreamDiagnostics.log("complete.received")
#endif
                    if let usage = json["usage"] as? [String: Any],
                        let promptTokens = usage["prompt_tokens"] as? Int,
                        let completionTokens = usage["completion_tokens"] as? Int {
                        let completedContent: String
                        if responseBuilder?.fullResponse.isEmpty ?? true,
                            let choices = json["choices"] as? [[String: Any]],
                            let first = choices.first,
                            let message = first["message"] as? [String: Any],
                            let content = message["content"] as? String {
                            completedContent = content
                        } else {
                            completedContent = responseBuilder?.fullResponse ?? ""
                        }
                        let tokenUsage = TokenUsage(
                            promptTokens: promptTokens,
                            completionTokens: completionTokens
                        )
                        continuation.yield(.complete(completedContent, usage: tokenUsage))
                        continuation.finish()
                    }

                case "chat.completion.tool_calls":
                    if let toolCallDicts = json["tool_calls"] as? [[String: Any]] {
                        var parsedToolCalls: [ExecutionToolCall] = []
                        for tcDict in toolCallDicts {
                            if let id = tcDict["id"] as? String,
                                let fnDict = tcDict["function"] as? [String: Any],
                                let name = fnDict["name"] as? String,
                                let arguments = fnDict["arguments"] as? String {
                                parsedToolCalls.append(ExecutionToolCall(
                                    id: id,
                                    function: ExecutionToolCallFunction(name: name, arguments: arguments)
                                ))
                            }
                        }
                        if !parsedToolCalls.isEmpty {
                            continuation.yield(.toolCalls(parsedToolCalls))
                        }
                        continuation.finish()
                    }

                case "image.generated":
                    if let path = json["path"] as? String {
                        continuation.yield(.image(URL(fileURLWithPath: path)))
                    }

                case "audio.generated":
                    if let path = json["path"] as? String {
                        continuation.yield(.audio(URL(fileURLWithPath: path)))
                    }

case "model.loading":
            if let status = json["status"] as? String {
                continuation.yield(.progress("Loading model: \(status)..."))
            }

        case "model.loaded":
            print("[VLMExecutor] Model load confirmed: \(json["model"] ?? "unknown")")

        case "error":
                    let errorMessage = json["message"] as? String ?? "Unknown Python error"
                    print("[Python Error] \(errorMessage)")
                    continuation.yield(.error(ExecutionError.pythonError(errorMessage)))
                    continuation.finish()

                default:
                    break
                }
            } catch {
                print("[VLMExecutor] Parse error: \(error)")
            }
        }
    }

    // Keep stream alive until complete
    while process?.isRunning == true && !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    continuation.finish()
}

    private func setupOutputHandlers() {
        // Stderr handler for debugging - capture all Python output
        stderrPipe?.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard let output = String(data: data, encoding: .utf8),
                  !output.isEmpty else { return }

            // Log each line separately for clarity
            let lines = output.components(separatedBy: .newlines)
            for line in lines where !line.isEmpty {
                print("[Python STDERR] \(line)")
            }
        }
    }

    private func messageType(for backend: RuntimeBackend) -> String {
        switch backend {
        case .image:
            return "image.generate"
        case .audio:
            return "audio.speech"
        case .music:
            return "music.generate"
        case .vlm, .llm:
            return "chat.completions"
        }
    }

    private func shouldRetry(error: Error) -> Bool {
        guard retryCount < maxRetries else { return false }

        // Retry on process crashes or timeouts
        if let execError = error as? ExecutionError {
            switch execError {
            case .processCrashed, .processNotRunning, .timeout:
                return true
            default:
                return false
            }
        }

        return false
    }
}

// MARK: - Bridge Line Buffer
private final class BridgeLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""

    func append(_ output: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        pending += output
        var lines: [String] = []

        while let newlineRange = pending.range(of: "\n") {
            let line = String(pending[..<newlineRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...newlineRange.lowerBound)

            if !line.isEmpty {
                lines.append(line)
            }
        }

        return lines
    }
}

// MARK: - Response Builder
private final class ResponseBuilder: @unchecked Sendable {
    private var _fullResponse: String = ""
    private let lock = NSLock()

    var fullResponse: String {
        lock.lock()
        defer { lock.unlock() }
        return _fullResponse
    }

    func append(_ token: String) {
        lock.lock()
        _fullResponse += token
        lock.unlock()
    }
}

// MARK: - Delegate Protocol
@MainActor
protocol VLMExecutionDelegate: AnyObject {
    func modelLoadingStarted(modelId: String)
    func modelLoadingCompleted(modelId: String)
    func modelLoadingFailed(modelId: String, error: Error)
    func executionWillRetry(attempt: Int)
    func executionDidFail(error: Error)
}
