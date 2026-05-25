import Foundation
import Combine
import Darwin

#if DEBUG
private enum VLMStreamDiagnostics {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MLXTRA_STREAM_DIAGNOSTICS"] == "1"
            || UserDefaults.standard.bool(forKey: "MLXtra.streamDiagnostics")
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

private enum VLMBridgeDiagnostics {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MLXTRA_BRIDGE_DEBUG"] == "1"
            || UserDefaults.standard.bool(forKey: "MLXtra.bridgeDebug")
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print(message())
    }
}

@MainActor
class VLMExecutor: NSObject, ModelExecutor {
    var backend: RuntimeBackend { .vlm }

    private(set) var isReady: Bool = false
    private(set) var isModelLoaded: Bool = false
    private(set) var currentModelId: String?
    private(set) var currentModelBackend: RuntimeBackend?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private let stdoutDispatcher = BridgeOutputDispatcher()
    private let stdoutLineBuffer = BridgeLineBuffer()
    private let stderrBuffer = BridgeStderrBuffer(maxLines: 24)
    private var currentRequest: ExecutionRequest?
    private var currentModelCacheKey: String?
    private var retryCount: Int = 0
    private let maxRetries: Int = 1

    weak var delegate: VLMExecutionDelegate?


    override init() {
        super.init()
    }

    deinit {
        let processToTerminate = process
        let stdinToClose = stdinPipe
        let stdoutToClose = stdoutPipe
        let stderrToClose = stderrPipe

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        stdoutDispatcher.handleEOF()
        stdoutDispatcher.removeAll()

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        stdinToClose?.fileHandleForWriting.closeFile()

        if let processToTerminate, processToTerminate.isRunning {
            processToTerminate.terminate()
            let pid = processToTerminate.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
                var zombieCheck: Int32 = 0
                if waitpid(pid, &zombieCheck, WNOHANG) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }

        stdoutToClose?.fileHandleForReading.closeFile()
        stderrToClose?.fileHandleForReading.closeFile()
    }


    func initialize() async throws {
        guard !isReady else { return }
        try await startBridge()
        isReady = true
    }

    func execute(request: ExecutionRequest) async throws -> AsyncStream<ExecutionEvent> {
        guard isReady else {
            throw ExecutionError.notInitialized
        }

        var requestRetryCount = 0
        while true {
            do {
                let stream = try await attemptExecute(request: request)
                retryCount = 0
                return stream
            } catch {
                guard shouldRetry(error: error, retryCount: requestRetryCount) else {
                    retryCount = 0
                    delegate?.executionDidFail(error: error)
                    throw error
                }

                requestRetryCount += 1
                retryCount = requestRetryCount
                delegate?.executionWillRetry(attempt: requestRetryCount)

                do {
                    try await restartBridge()
                } catch {
                    retryCount = 0
                    delegate?.executionDidFail(error: error)
                    throw error
                }
            }
        }
    }

    func preload(modelId: String, backend: RuntimeBackend) async throws {
        if !isReady {
            try await initialize()
        }

        let modelCacheKey = "\(backend.rawValue):\(modelId)"
        guard currentModelCacheKey != modelCacheKey || !isModelLoaded else {
            return
        }

        isModelLoaded = false
        try await loadModel(modelId, backend: backend)
        currentModelCacheKey = modelCacheKey
        currentModelId = modelId
        currentModelBackend = backend
    }

    func terminate() async {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutDispatcher.handleEOF()
        stdoutDispatcher.removeAll()
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        let processToTerminate = process
        let stdinToClose = stdinPipe
        let stdoutToClose = stdoutPipe
        let stderrToClose = stderrPipe

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        if let processToTerminate, processToTerminate.isRunning {
            processToTerminate.terminate()
            let exited = await waitForProcessExit(processToTerminate, timeout: 2.0)
            if !exited, processToTerminate.isRunning {
                kill(processToTerminate.processIdentifier, SIGKILL)
                _ = await waitForProcessExit(processToTerminate, timeout: 1.0)
            }
        }

        stdinToClose?.fileHandleForWriting.closeFile()

        stdoutToClose?.fileHandleForReading.closeFile()
        stderrToClose?.fileHandleForReading.closeFile()

        isReady = false
        isModelLoaded = false
        currentModelId = nil
        currentModelBackend = nil
        currentModelCacheKey = nil
        currentRequest = nil
        retryCount = 0
    }


    private func startBridge() async throws {
        let runtimeManager = RuntimeManager()
        try await runtimeManager.initialize()

        let pythonPath = runtimeManager.pythonExecutablePath()
        let bridgePath = runtimeManager.bridgeScriptPath()

        process = Process()
        process?.executableURL = pythonPath
        process?.arguments = [bridgePath.path]
        stderrBuffer.clear()

        var cleanEnv = ProcessInfo.processInfo.environment
        cleanEnv.removeValue(forKey: "PYTHONPATH")
        cleanEnv.removeValue(forKey: "VIRTUAL_ENV")
        cleanEnv.removeValue(forKey: "CONDA_PREFIX")
        cleanEnv.removeValue(forKey: "CONDA_DEFAULT_ENV")
        cleanEnv.removeValue(forKey: "PYENV_ROOT")
        cleanEnv.removeValue(forKey: "PYENV_VERSION")

        // Set PYTHONHOME to the bundled framework so the venv can find
        // the standard library and C extension modules (math, select, etc.)
        cleanEnv["PYTHONHOME"] = runtimeManager.pythonHomePath().path

        cleanEnv["PYTHONDONTWRITEBYTECODE"] = "1"
        cleanEnv["PYTHONUNBUFFERED"] = "1"
        if VLMBridgeDiagnostics.isEnabled {
            cleanEnv["MLXTRA_BRIDGE_DEBUG"] = "1"
        } else {
            cleanEnv.removeValue(forKey: "MLXTRA_BRIDGE_DEBUG")
        }
        cleanEnv["HF_HOME"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface").path
        cleanEnv["HF_HUB_CACHE"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub").path
        cleanEnv["ACESTEP_CHECKPOINTS_DIR"] = runtimeManager.checkpointsPath.path
        cleanEnv["ACESTEP_PYTHON"] = runtimeManager.acestepPythonExecutablePath().path

        // Disable Metal validation to prevent crashes with ACE-Step/MLX
        // Metal validation can trigger false positives with certain compute shaders
        cleanEnv["MTL_DEBUG_LAYER"] = "0"
        cleanEnv["MTL_SHADER_VALIDATION"] = "0"

        process?.environment = cleanEnv

        VLMBridgeDiagnostics.log("[VLMExecutor] Starting Python bridge at \(pythonPath.path)")
        VLMBridgeDiagnostics.log("[VLMExecutor] Bridge script at \(bridgePath.path)")

        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        stderrPipe = Pipe()

        process?.standardInput = stdinPipe
        process?.standardOutput = stdoutPipe
        process?.standardError = stderrPipe

        setupOutputHandlers()
        let readyWaiter = installReadyHandler()

        do {
            try process?.run()

            try await waitForReady(readyWaiter, timeout: 30.0)
        } catch {
            stdoutDispatcher.unregister(readyWaiter.handlerID)
            throw error
        }
    }

    private func restartBridge() async throws {
        await terminate()
        do {
            try await startBridge()
            isReady = true
        } catch {
            isReady = false
            isModelLoaded = false
            currentModelId = nil
            currentModelBackend = nil
            currentModelCacheKey = nil
            currentRequest = nil
            retryCount = 0
            throw error
        }
    }

    private func installReadyHandler() -> ReadyWaiter {
        let readyState = ReadyState()
        let handlerID = stdoutDispatcher.register(
            shouldHandle: { json in
                guard let type = json["type"] as? String else { return false }
                return type == "system.ready" || type == "error"
            },
            handler: { [weak readyState] json in
                guard let type = json["type"] as? String else { return }
                if type == "system.ready" {
                    VLMBridgeDiagnostics.log("[VLMExecutor] Bridge is ready")
                    Task { await readyState?.setReady() }
                } else if type == "error" {
                    let message = json["message"] as? String ?? "Unknown error"
                    VLMBridgeDiagnostics.log("[VLMExecutor] Bridge initialization error: \(message)")
                }
            }
        )
        return ReadyWaiter(state: readyState, handlerID: handlerID)
    }

    private func waitForReady(_ waiter: ReadyWaiter, timeout: TimeInterval) async throws {
        let startTime = Date()
        defer { stdoutDispatcher.unregister(waiter.handlerID) }

        while !(await waiter.state.isReady) {
            if process?.isRunning == false {
                throw stoppedProcessError()
            }
            if Date().timeIntervalSince(startTime) > timeout {
                VLMBridgeDiagnostics.log("[VLMExecutor] Timeout waiting for bridge ready signal")
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

private struct ReadyWaiter {
    let state: ReadyState
    let handlerID: UUID
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

private struct ModelLoadWaiter {
    let state: ModelLoadedState
    let handlerID: UUID
}

private struct ResponseStreamHandle {
    let stream: AsyncStream<ExecutionEvent>
    let handlerID: UUID
}

private final class StreamFinishState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !finished else { return false }
        finished = true
        return true
    }
}

    private func attemptExecute(request: ExecutionRequest) async throws -> AsyncStream<ExecutionEvent> {
        currentRequest = request

        let modelCacheKey = "\(request.backend.rawValue):\(request.modelId)"
        if currentModelCacheKey != modelCacheKey {
            isModelLoaded = false
            try await loadModel(
                request.modelId,
                backend: request.backend,
                parameters: request.parameters
            )
            currentModelCacheKey = modelCacheKey
            currentModelId = request.modelId
            currentModelBackend = request.backend
        }

        let messages = request.messages.map { $0.toDictionary() }
        var payload: [String: Any] = [
            "request_id": request.requestID,
            "type": Self.messageType(for: request.backend),
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

        let responseStream = makeResponseStream(
            requestID: request.requestID,
            modelId: request.modelId,
            backend: request.backend
        )
        do {
            try await sendRequest(payload)
        } catch {
            stdoutDispatcher.unregister(responseStream.handlerID)
            throw error
        }

        return responseStream.stream
    }

    private func loadModel(
        _ modelId: String,
        backend: RuntimeBackend,
        parameters: [String: Any]? = nil
    ) async throws {
        delegate?.modelLoadingStarted(modelId: modelId)
        delegate?.modelLoadingProgress(
            ModelLoadProgress(
                modelId: modelId,
                backend: backend,
                phase: .preparing,
                detail: "Preparing runtime"
            )
        )

        let requestID = UUID().uuidString
        var payload: [String: Any] = [
            "request_id": requestID,
            "type": "init",
            "model_id": modelId,
            "backend": backend.rawValue
        ]
        if let parameters {
            payload["parameters"] = parameters
        }

        let waiter = installModelLoadHandler(requestID: requestID, modelId: modelId, backend: backend)

        do {
            try await sendRequest(payload)
            try await waitForModelLoaded(waiter)
            isModelLoaded = true
            delegate?.modelLoadingCompleted(modelId: modelId)
        } catch {
            stdoutDispatcher.unregister(waiter.handlerID)
            delegate?.modelLoadingFailed(modelId: modelId, error: error)
            throw error
        }
    }

    private func installModelLoadHandler(requestID: String, modelId: String, backend: RuntimeBackend) -> ModelLoadWaiter {
        let loadedState = ModelLoadedState()
        let handlerID = stdoutDispatcher.register(
            requestID: requestID,
            shouldHandle: { json in
                guard let type = json["type"] as? String else { return false }
                return type == "model.loaded"
                    || type == "model.initialized"
                    || type == "model.loading"
                    || type == "error"
            },
            handler: { [weak self, weak loadedState] json in
                guard let type = json["type"] as? String else { return }
                switch type {
                case "model.loaded", "model.initialized":
                    VLMBridgeDiagnostics.log("[VLMExecutor] Model load handler: setting loaded (type=\(type))")
                    loadedState?.setLoaded()
                case "model.loading":
                    let progress = ModelLoadProgress.bridgeEvent(
                        json,
                        fallbackModelId: modelId,
                        fallbackBackend: backend
                    )
                    Task { @MainActor in
                        self?.delegate?.modelLoadingProgress(progress)
                    }
                    if let status = json["status"] as? String {
                        VLMBridgeDiagnostics.log("[VLMExecutor] Model loading status: \(status)")
                    }
                case "error":
                    let message = json["message"] as? String ?? "Unknown error"
                    VLMBridgeDiagnostics.log("[VLMExecutor] Model loading error: \(message)")
                    loadedState?.setError(message)
                default:
                    break
                }
            }
        )

        VLMBridgeDiagnostics.log("[VLMExecutor] waitForModelLoaded: handler installed for request \(requestID)")
        return ModelLoadWaiter(state: loadedState, handlerID: handlerID)
    }

    private func waitForModelLoaded(_ waiter: ModelLoadWaiter) async throws {
        let startTime = Date()
        let timeout: TimeInterval = 600.0 // 10 minutes timeout for model loading

        defer { stdoutDispatcher.unregister(waiter.handlerID) }

        while !waiter.state.isLoaded {
            if Task.isCancelled {
                VLMBridgeDiagnostics.log("[VLMExecutor] waitForModelLoaded detected Task.isCancelled")
                throw CancellationError()
            }
            if let error = waiter.state.errorMessage {
                throw ExecutionError.pythonError("Model loading failed: \(error)")
            }
            if process?.isRunning == false {
                throw stoppedProcessError()
            }
            if Date().timeIntervalSince(startTime) > timeout {
                VLMBridgeDiagnostics.log("[VLMExecutor] Timeout waiting for model loaded signal")
                throw ExecutionError.timeout
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        VLMBridgeDiagnostics.log("[VLMExecutor] Model load complete, isModelLoaded will be set to true")
    }

    private func sendRequest(_ payload: [String: Any]) async throws {
        guard stdinPipe != nil else {
            throw stoppedProcessError()
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
                throw stoppedProcessError()
            }
            throw ExecutionError.encodingFailed
        }
    }

    private func makeResponseStream(requestID: String, modelId: String, backend: RuntimeBackend) -> ResponseStreamHandle {
        let responseBuilder = ResponseBuilder()
        let finishState = StreamFinishState()
        let handlerID = UUID()
        let dispatcher = stdoutDispatcher
        let stderrBuffer = stderrBuffer

        let stream = AsyncStream<ExecutionEvent> { continuation in
            continuation.yield(.started)

            dispatcher.register(
                id: handlerID,
                requestID: requestID,
                shouldHandle: { json in
                    guard let type = json["type"] as? String else { return false }
                    return type == "chat.completion.chunk"
                        || type == "chat.completion.complete"
                        || type == "chat.completion.tool_calls"
                        || type == "image.generated"
                        || type == "audio.generated"
                        || type == "model.loading"
                        || type == "model.loaded"
                        || type == "error"
                },
                onEOF: {
                    guard finishState.finish() else { return }
                    let errorDetail = stderrBuffer.summary()
                    if errorDetail.isEmpty {
                        continuation.yield(.error(ExecutionError.processNotRunning))
                    } else {
                        continuation.yield(.error(ExecutionError.processStopped(errorDetail)))
                    }
                    continuation.finish()
                },
                handler: { json in
                    guard !finishState.isFinished,
                          let type = json["type"] as? String else { return }

#if DEBUG
                    VLMStreamDiagnostics.log("dispatch.received requestID=\(requestID) type=\(type)")
#endif

                    switch type {
                    case "chat.completion.chunk":
                        if let choices = json["choices"] as? [[String: Any]],
                           let first = choices.first,
                           let delta = first["delta"] as? [String: Any],
                           let content = delta["content"] as? String {
#if DEBUG
                            let yieldStartedAt = VLMStreamDiagnostics.now()
                            VLMStreamDiagnostics.log("chunk.received requestID=\(requestID) tokenChars=\(content.count)")
#endif
                            responseBuilder.append(content)
                            continuation.yield(.token(content))
#if DEBUG
                            let yieldFinishedAt = VLMStreamDiagnostics.now()
                            VLMStreamDiagnostics.log("chunk.yielded requestID=\(requestID) tokenChars=\(content.count) elapsedMs=\(String(format: "%.2f", (yieldFinishedAt - yieldStartedAt) * 1000))")
#endif
                        }

                    case "chat.completion.complete":
#if DEBUG
                        VLMStreamDiagnostics.log("complete.received requestID=\(requestID)")
#endif
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
                        let usage = json["usage"] as? [String: Any]
                        let performance = json["performance"] as? [String: Any]
                        let tokenUsage = TokenUsage(
                            promptTokens: usage?["prompt_tokens"] as? Int ?? 0,
                            completionTokens: usage?["completion_tokens"] as? Int ?? 0,
                            promptTokensPerSecond: bridgeDouble(performance?["prompt_tokens_per_second"]),
                            generationTokensPerSecond: bridgeDouble(performance?["generation_tokens_per_second"])
                                ?? bridgeDouble(performance?["tokens_per_second"]),
                            peakMemoryGB: bridgeDouble(performance?["peak_memory_gb"])
                        )
                        continuation.yield(.complete(completedContent, usage: tokenUsage))
                        if finishState.finish() {
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
                                    parsedToolCalls.append(
                                        ExecutionToolCall(
                                            id: id,
                                            function: ExecutionToolCallFunction(name: name, arguments: arguments)
                                        )
                                    )
                                }
                            }
                            if !parsedToolCalls.isEmpty {
                                continuation.yield(.toolCalls(parsedToolCalls))
                            }
                            if finishState.finish() {
                                continuation.finish()
                            }
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
                        let progress = ModelLoadProgress.bridgeEvent(
                            json,
                            fallbackModelId: modelId,
                            fallbackBackend: backend
                        )
                        continuation.yield(.progress(progress.detail ?? progress.phase.displayTitle))
                        continuation.yield(.modelLoadProgress(progress))

                    case "model.loaded":
                        VLMBridgeDiagnostics.log("[VLMExecutor] Model load confirmed: \(json["model"] ?? "unknown")")

                    case "error":
                        let errorMessage = json["message"] as? String ?? "Unknown Python error"
                        VLMBridgeDiagnostics.log("[Python Error] \(errorMessage)")
                        continuation.yield(.error(ExecutionError.pythonError(errorMessage)))
                        if finishState.finish() {
                            continuation.finish()
                        }

                    default:
                        break
                    }
                }
            )

            continuation.onTermination = { _ in
                _ = finishState.finish()
                dispatcher.unregister(handlerID)
            }
        }

        return ResponseStreamHandle(stream: stream, handlerID: handlerID)
    }

    private func setupOutputHandlers() {
        let dispatcher = stdoutDispatcher
        let lineBuffer = stdoutLineBuffer
        let stderrBuffer = stderrBuffer

        stdoutPipe?.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                dispatcher.handleEOF()
                return
            }
            guard let output = String(data: data, encoding: .utf8),
                  !output.isEmpty else { return }

            for line in lineBuffer.append(output) {
#if DEBUG
                if VLMStreamDiagnostics.isEnabled {
                    VLMBridgeDiagnostics.log("[VLMExecutor] Received: \(line.prefix(200))...")
                }
#endif

                do {
                    guard let lineData = line.data(using: .utf8),
                          let json = try JSONSerialization.jsonObject(with: lineData) as? BridgeJSONMessage else {
                        VLMBridgeDiagnostics.log("[VLMExecutor] Could not parse JSON or missing type field")
                        continue
                    }
                    dispatcher.dispatch(json)
                } catch {
                    VLMBridgeDiagnostics.log("[VLMExecutor] Parse error: \(error)")
                }
            }
        }

        stderrPipe?.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            guard let output = String(data: data, encoding: .utf8),
                  !output.isEmpty else { return }

            let lines = output.components(separatedBy: .newlines)
            for line in lines where !line.isEmpty {
                stderrBuffer.append(line)
                VLMBridgeDiagnostics.log("[Python STDERR] \(line)")
            }
        }
    }

    private func stoppedProcessError() -> ExecutionError {
        let errorDetail = stderrBuffer.summary()
        if errorDetail.isEmpty {
            return .processNotRunning
        }
        return .processStopped(errorDetail)
    }

    private nonisolated func waitForProcessExit(_ process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !process.isRunning
    }

    nonisolated static func messageType(for backend: RuntimeBackend) -> String {
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

    private func shouldRetry(error: Error, retryCount: Int) -> Bool {
        Self.shouldRetry(error: error, retryCount: retryCount, maxRetries: maxRetries)
    }

    nonisolated static func shouldRetry(error: Error, retryCount: Int, maxRetries: Int) -> Bool {
        guard retryCount < maxRetries else { return false }

        if let execError = error as? ExecutionError {
            switch execError {
            case .processCrashed, .processNotRunning, .processStopped, .timeout:
                return true
            default:
                return false
            }
        }

        return false
    }
}

typealias BridgeJSONMessage = [String: Any]

private func bridgeDouble(_ value: Any?) -> Double? {
    if let value = value as? Double {
        return value.isFinite ? value : nil
    }
    if let value = value as? Int {
        return Double(value)
    }
    if let value = value as? NSNumber {
        let doubleValue = value.doubleValue
        return doubleValue.isFinite ? doubleValue : nil
    }
    return nil
}

struct BridgeOutputRoute {
    let requestID: String?
    let shouldHandle: @Sendable (BridgeJSONMessage) -> Bool
    let onEOF: @Sendable () -> Void
    let handler: @Sendable (BridgeJSONMessage) -> Void
}

final class BridgeOutputDispatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [UUID: BridgeOutputRoute] = [:]

    @discardableResult
    func register(
        id: UUID = UUID(),
        requestID: String? = nil,
        shouldHandle: @escaping @Sendable (BridgeJSONMessage) -> Bool = { _ in true },
        onEOF: @escaping @Sendable () -> Void = {},
        handler: @escaping @Sendable (BridgeJSONMessage) -> Void
    ) -> UUID {
        lock.lock()
        routes[id] = BridgeOutputRoute(
            requestID: requestID,
            shouldHandle: shouldHandle,
            onEOF: onEOF,
            handler: handler
        )
        lock.unlock()
        return id
    }

    func unregister(_ id: UUID) {
        lock.lock()
        routes.removeValue(forKey: id)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        routes.removeAll()
        lock.unlock()
    }

    func dispatch(_ json: BridgeJSONMessage) {
        let requestID = json["request_id"] as? String
        let routes = snapshotRoutes()

        for route in routes {
            if let routeRequestID = route.requestID {
                guard routeRequestID == requestID else { continue }
            } else if requestID != nil {
                continue
            }

            if route.shouldHandle(json) {
                route.handler(json)
            }
        }
    }

    func handleEOF() {
        for route in snapshotRoutes() {
            route.onEOF()
        }
    }

    private func snapshotRoutes() -> [BridgeOutputRoute] {
        lock.lock()
        let routes = Array(routes.values)
        lock.unlock()
        return routes
    }
}

private final class BridgeStderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maxLines: Int
    private var lines: [String] = []

    init(maxLines: Int) {
        self.maxLines = max(1, maxLines)
    }

    func append(_ line: String) {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return }

        lock.lock()
        lines.append(trimmedLine)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        lock.unlock()
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }

    func summary() -> String {
        lock.lock()
        let snapshot = lines
        lock.unlock()
        return snapshot.joined(separator: "\n")
    }
}

final class BridgeLineBuffer: @unchecked Sendable {
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

final class ResponseBuilder: @unchecked Sendable {
    private var parts: [String] = []
    private let lock = NSLock()

    var fullResponse: String {
        lock.lock()
        defer { lock.unlock() }
        return parts.joined()
    }

    func append(_ token: String) {
        lock.lock()
        parts.append(token)
        lock.unlock()
    }
}

@MainActor
protocol VLMExecutionDelegate: AnyObject {
    func modelLoadingStarted(modelId: String)
    func modelLoadingProgress(_ progress: ModelLoadProgress)
    func modelLoadingCompleted(modelId: String)
    func modelLoadingFailed(modelId: String, error: Error)
    func executionWillRetry(attempt: Int)
    func executionDidFail(error: Error)
}
