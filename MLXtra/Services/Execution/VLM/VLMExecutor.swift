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
            || DiagnosticsLogStore.isVerboseBridgeLoggingEnabled
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        print(text)
        DiagnosticsLogStore.log(text, category: .bridge, level: .debug)
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
    private let stderrBuffer = BridgeStderrBuffer(maxLines: 24)
    private lazy var outputProcessor = VLMBridgeOutputProcessor(
        dispatcher: stdoutDispatcher,
        stderrBuffer: stderrBuffer,
        log: { message in
#if DEBUG
            if VLMStreamDiagnostics.isEnabled {
                print(message)
            }
#else
            _ = message
#endif
        }
    )
    private let runtimeProvider: any VLMBridgeRuntimeProviding
    private var currentRequest: ExecutionRequest?
    private var currentModelCacheKey: String?
    private var retryCount: Int = 0
    private let maxRetries: Int = 1

    weak var delegate: VLMExecutionDelegate?


    init(runtimeProvider: any VLMBridgeRuntimeProviding = RuntimeManager()) {
        self.runtimeProvider = runtimeProvider
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
                    DiagnosticsLogStore.log(
                        "Local bridge request failed",
                        category: .bridge,
                        level: .error,
                        details: error.localizedDescription
                    )
                    throw error
                }

                requestRetryCount += 1
                retryCount = requestRetryCount
                delegate?.executionWillRetry(attempt: requestRetryCount)
                DiagnosticsLogStore.log(
                    "Retrying local bridge request",
                    category: .bridge,
                    level: .warning,
                    details: "Attempt \(requestRetryCount + 1): \(error.localizedDescription)"
                )

                do {
                    try await restartBridge()
                } catch {
                    retryCount = 0
                    delegate?.executionDidFail(error: error)
                    DiagnosticsLogStore.log(
                        "Local bridge restart failed",
                        category: .bridge,
                        level: .error,
                        details: error.localizedDescription
                    )
                    throw error
                }
            }
        }
    }

    func preload(modelId: String, backend: RuntimeBackend, parameters: [String: Any]? = nil) async throws {
        if !isReady {
            try await initialize()
        }

        let modelCacheKey = "\(backend.rawValue):\(modelId)"
        guard currentModelCacheKey != modelCacheKey || !isModelLoaded else {
            return
        }

        isModelLoaded = false
        try await loadModel(modelId, backend: backend, parameters: parameters)
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
        let runtimeManager = runtimeProvider
        try await runtimeManager.initialize()

        let pythonPath = runtimeManager.pythonExecutablePath()
        let bridgePath = runtimeManager.bridgeScriptPath()

        process = Process()
        process?.executableURL = pythonPath
        process?.arguments = [bridgePath.path]
        stderrBuffer.clear()

        process?.environment = VLMBridgeEnvironment.make(
            pythonHomePath: runtimeManager.pythonHomePath(),
            checkpointsPath: runtimeManager.checkpointsPath,
            acestepPythonPath: runtimeManager.acestepPythonExecutablePath(),
            magentaPythonPath: runtimeManager.magentaPythonExecutablePath(),
            bridgeDebugEnabled: VLMBridgeDiagnostics.isEnabled
        )

        VLMBridgeDiagnostics.log("[VLMExecutor] Starting Python bridge at \(pythonPath.path)")
        VLMBridgeDiagnostics.log("[VLMExecutor] Bridge script at \(bridgePath.path)")
        DiagnosticsLogStore.log(
            "Starting local Python bridge",
            category: .bridge,
            level: .info,
            details: "Python: \(pythonPath.path)\nBridge: \(bridgePath.path)"
        )

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
            await terminate()
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
                    DiagnosticsLogStore.log("Local Python bridge is ready", category: .bridge, level: .info)
                    readyState?.setReady()
                } else if type == "error" {
                    let message = json["message"] as? String ?? "Unknown error"
                    VLMBridgeDiagnostics.log("[VLMExecutor] Bridge initialization error: \(message)")
                    DiagnosticsLogStore.log(
                        "Local Python bridge initialization failed",
                        category: .bridge,
                        level: .error,
                        details: message
                    )
                    readyState?.setError(message)
                }
            }
        )
        return ReadyWaiter(state: readyState, handlerID: handlerID)
    }

    private func waitForReady(_ waiter: ReadyWaiter, timeout: TimeInterval) async throws {
        let startTime = Date()
        defer { stdoutDispatcher.unregister(waiter.handlerID) }

        while !waiter.state.isReady {
            if let error = waiter.state.errorMessage {
                throw ExecutionError.pythonError("Bridge initialization failed: \(error)")
            }
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

        let payload = VLMRequestPayloadBuilder.executionPayload(for: request)

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
        DiagnosticsLogStore.log(
            "Loading local model",
            category: .runtime,
            level: .info,
            details: "\(backend.rawValue): \(modelId)"
        )
        delegate?.modelLoadingProgress(
            ModelLoadProgress(
                modelId: modelId,
                backend: backend,
                phase: .preparing,
                detail: "Preparing runtime"
            )
        )

        let requestID = UUID().uuidString
        let payload = VLMRequestPayloadBuilder.modelLoadPayload(
            requestID: requestID,
            modelId: modelId,
            backend: backend,
            parameters: parameters
        )

        let waiter = installModelLoadHandler(requestID: requestID, modelId: modelId, backend: backend)

        do {
            try await sendRequest(payload)
            try await waitForModelLoaded(waiter)
            isModelLoaded = true
            delegate?.modelLoadingCompleted(modelId: modelId)
            DiagnosticsLogStore.log(
                "Local model loaded",
                category: .runtime,
                level: .info,
                details: "\(backend.rawValue): \(modelId)"
            )
        } catch {
            stdoutDispatcher.unregister(waiter.handlerID)
            delegate?.modelLoadingFailed(modelId: modelId, error: error)
            DiagnosticsLogStore.log(
                "Local model failed to load",
                category: .runtime,
                level: .error,
                details: "\(backend.rawValue): \(modelId)\n\(error.localizedDescription)"
            )
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
            handler: { [weak loadedState] json in
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
                    loadedState?.appendProgress(progress)
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

        while true {
            emitPendingModelLoadProgress(from: waiter)
            if waiter.state.isLoaded {
                break
            }
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
        emitPendingModelLoadProgress(from: waiter)
        VLMBridgeDiagnostics.log("[VLMExecutor] Model load complete, isModelLoaded will be set to true")
    }

    private func emitPendingModelLoadProgress(from waiter: ModelLoadWaiter) {
        for progress in waiter.state.drainProgress() {
            delegate?.modelLoadingProgress(progress)
        }
    }

    private func sendRequest(_ payload: [String: Any]) async throws {
        guard let stdinHandle = stdinPipe?.fileHandleForWriting else {
            throw stoppedProcessError()
        }

        try VLMBridgeRequestWriter.write(
            payload,
            to: stdinHandle,
            processIsRunning: { [weak self] in self?.process?.isRunning },
            stoppedProcessError: { [weak self] in
                self?.stoppedProcessError() ?? .processNotRunning
            }
        )
    }

    private func makeResponseStream(requestID: String, modelId: String, backend: RuntimeBackend) -> ResponseStreamHandle {
        let responseParser = VLMResponseEventParser(modelId: modelId, backend: backend)
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
                    VLMResponseEventParser.handles(json)
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

                    guard let parsedResponse = responseParser.parse(json) else { return }

                    if type == "model.loaded" {
                        VLMBridgeDiagnostics.log("[VLMExecutor] Model load confirmed: \(json["model"] ?? "unknown")")
                    } else if type == "error" {
                        let errorMessage = json["message"] as? String ?? "Unknown Python error"
                        VLMBridgeDiagnostics.log("[Python Error] \(errorMessage)")
                        DiagnosticsLogStore.log(
                            "Python bridge returned an error",
                            category: .bridge,
                            level: .error,
                            details: errorMessage
                        )
                    }

#if DEBUG
                    if type == "chat.completion.chunk",
                       case .token(let content) = parsedResponse.events.first {
                            let yieldStartedAt = VLMStreamDiagnostics.now()
                            VLMStreamDiagnostics.log("chunk.received requestID=\(requestID) tokenChars=\(content.count)")
                            for event in parsedResponse.events {
                                continuation.yield(event)
                            }
                            let yieldFinishedAt = VLMStreamDiagnostics.now()
                            VLMStreamDiagnostics.log("chunk.yielded requestID=\(requestID) tokenChars=\(content.count) elapsedMs=\(String(format: "%.2f", (yieldFinishedAt - yieldStartedAt) * 1000))")
                        } else {
                            if type == "chat.completion.complete" {
                                VLMStreamDiagnostics.log("complete.received requestID=\(requestID)")
                            }
                            for event in parsedResponse.events {
                                continuation.yield(event)
                            }
                        }
#else
                    for event in parsedResponse.events {
                        continuation.yield(event)
                    }
#endif

                    if parsedResponse.finishesStream, finishState.finish() {
                        continuation.finish()
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
        let outputProcessor = outputProcessor

        stdoutPipe?.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                outputProcessor.finishStdout()
                return
            }

            outputProcessor.appendStdout(data)
        }

        stderrPipe?.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                outputProcessor.finishStderr()
                return
            }

            outputProcessor.appendStderr(data)
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
        VLMRequestPayloadBuilder.messageType(for: backend)
    }

    private func shouldRetry(error: Error, retryCount: Int) -> Bool {
        Self.shouldRetry(error: error, retryCount: retryCount, maxRetries: maxRetries)
    }

    nonisolated static func shouldRetry(error: Error, retryCount: Int, maxRetries: Int) -> Bool {
        guard retryCount < maxRetries else { return false }

        if let execError = error as? ExecutionError {
            switch execError {
            case .processCrashed, .processNotRunning, .processStopped, .pipeWriteFailed, .timeout:
                return true
            default:
                return false
            }
        }

        return false
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
