import Foundation
import Combine

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
                try await restartBridge()
                return try await attemptExecute(request: request)
            } else {
                throw error
            }
        }
    }

    func terminate() async {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        process?.terminate()
        process = nil
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
        try await startBridge()
    }

    private func waitForReady(timeout: TimeInterval) async throws {
        let startTime = Date()
        let readyState = ReadyState()

        stdoutPipe?.fileHandleForReading.readabilityHandler = { [weak readyState] handle in
            let data = handle.availableData
            guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { return }

            print("[VLMExecutor] Bridge output: \(line)")

            do {
                if let json = try JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as? [String: Any],
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
            "type": request.backend == .image ? "image.generate" : "chat.completions",
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

        // Pass chat_template_kwargs if provided (e.g., enable_thinking)
        if let chatTemplateKwargs = request.chatTemplateKwargs {
            payload["chat_template_kwargs"] = chatTemplateKwargs
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

        // Wait for model loaded
        try await waitForModelLoaded()

        isModelLoaded = true

        delegate?.modelLoadingCompleted(modelId: modelId)
    }

    private func waitForModelLoaded() async throws {
        // Implementation would parse stdout for model.loaded event
        // For now, simplified
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms placeholder
    }

    private func sendRequest(_ payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ExecutionError.encodingFailed
        }

        let line = json + "\n"
        guard let lineData = line.data(using: .utf8) else {
            throw ExecutionError.encodingFailed
        }

        stdinPipe?.fileHandleForWriting.write(lineData)
    }

    private func processStream(continuation: AsyncStream<ExecutionEvent>.Continuation) async {
        continuation.yield(.started)

        let responseBuilder = ResponseBuilder()

        stdoutPipe?.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { return }

            // Debug: Log all received lines
            print("[VLMExecutor] Received: \(line.prefix(200))...")

            do {
                guard let json = try JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as? [String: Any],
                      let type = json["type"] as? String else {
                    print("[VLMExecutor] Could not parse JSON or missing type field")
                    return
                }

                switch type {
                case "chat.completion.chunk":
                    if let choices = json["choices"] as? [[String: Any]],
                       let first = choices.first,
                       let delta = first["delta"] as? [String: Any],
                       let content = delta["content"] as? String {
                        responseBuilder.append(content)
                        continuation.yield(.token(content))
                    }

                case "chat.completion.complete":
                    if let usage = json["usage"] as? [String: Any],
                       let promptTokens = usage["prompt_tokens"] as? Int,
                       let completionTokens = usage["completion_tokens"] as? Int {
                        let completedContent: String
                        if responseBuilder.fullResponse.isEmpty,
                           let choices = json["choices"] as? [[String: Any]],
                           let first = choices.first,
                           let message = first["message"] as? [String: Any],
                           let content = message["content"] as? String {
                            completedContent = content
                        } else {
                            completedContent = responseBuilder.fullResponse
                        }
                        let tokenUsage = TokenUsage(
                            promptTokens: promptTokens,
                            completionTokens: completionTokens
                        )
                        continuation.yield(.complete(completedContent, usage: tokenUsage))
                        continuation.finish()
                    }

                case "image.generated":
                    if let path = json["path"] as? String {
                        continuation.yield(.image(URL(fileURLWithPath: path)))
                    }

                case "model.loading":
                    if let status = json["status"] as? String {
                        continuation.yield(.progress("Loading model: \(status)..."))
                    }

            case "error":
                let errorMessage = json["message"] as? String ?? "Unknown Python error"
                print("[Python Error] \(errorMessage)")
                continuation.yield(.error(ExecutionError.pythonError(errorMessage)))
                continuation.finish()

                default:
                    break
                }
            } catch {
                // Ignore parse errors
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
