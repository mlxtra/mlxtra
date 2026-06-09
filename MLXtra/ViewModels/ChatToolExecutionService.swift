import Foundation

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
        guard !Task.isCancelled else { return .cancelled }
        guard await runtimeManager.isModelDownloadedOffMain(model: plan.model) else {
            DiagnosticsLogStore.log(
                "\(plan.operationName) requires a model download",
                category: .generation,
                level: .info,
                details: "\(plan.model.name) (\(plan.model.modelId))"
            )
            return .downloadRequired(plan.model)
        }
        guard !Task.isCancelled else { return .cancelled }

        var lastError: Error?
        for attempt in 0...1 {
            do {
                DiagnosticsLogStore.log(
                    "Starting \(plan.operationName)",
                    category: .generation,
                    level: .info,
                    details: "Attempt \(attempt + 1)\nTool: \(plan.functionName)\nModel: \(plan.model.name) (\(plan.model.modelId))\nBackend: \(plan.request.backend.rawValue)"
                )
                return try await executeMediaToolAttempt(plan: plan, onUpdate: onUpdate)
            } catch is CancellationError {
                DiagnosticsLogStore.log(
                    "\(plan.operationName) cancelled",
                    category: .generation,
                    level: .info
                )
                return .cancelled
            } catch {
                lastError = error
                guard attempt == 0, shouldRetryMediaTool(error) else {
                    break
                }
                DiagnosticsLogStore.log(
                    "\(plan.operationName) will retry after local engine failure",
                    category: .generation,
                    level: .warning,
                    details: error.localizedDescription
                )
                onUpdate(.progress("Restarting local engine..."))
                await modelExecutor.terminate()
            }
        }

        return failedMediaToolOutcome(plan: plan, error: lastError)
    }

    private func shouldRetryMediaTool(_ error: Error) -> Bool {
        guard let execError = error as? ExecutionError else {
            return false
        }

        switch execError {
        case .processCrashed, .processNotRunning, .processStopped, .pipeWriteFailed, .timeout:
            return true
        default:
            return false
        }
    }

    private func failedMediaToolOutcome(plan: ChatMediaToolExecutionPlan, error: Error?) -> ChatToolExecutionOutcome {
        let rawDetail = error?.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail = rawDetail.isEmpty ? "Unknown error" : rawDetail
        DiagnosticsLogStore.log(
            "\(plan.operationName) failed",
            category: .generation,
            level: .error,
            details: detail
        )
        return .failedToolMessage(
            "\(plan.unavailablePrefix): \(detail)",
            localEngineErrorMessage: "Local engine stopped: \(detail)"
        )
    }

    private func executeMediaToolAttempt(
        plan: ChatMediaToolExecutionPlan,
        onUpdate: @escaping @MainActor (ChatToolExecutionUpdate) -> Void
    ) async throws -> ChatToolExecutionOutcome {
        do {
            try Task.checkCancellation()
            if let preflightErrorMessage = plan.preflightErrorMessage {
                return .failedToolMessage(
                    "\(plan.unavailablePrefix): \(preflightErrorMessage)",
                    localEngineErrorMessage: preflightErrorMessage
                )
            }
            if !modelExecutor.isReady {
                try await modelExecutor.initialize()
            }
            try Task.checkCancellation()
            let startedAt = Date()
            var firstOutputAt: Date?
            var observedTokenEvents = 0
            var completionTokenCount = 0
            var backendTokensPerSecond: Double?
            let stream = try await modelExecutor.execute(request: plan.request)
            try Task.checkCancellation()
            var generatedAssetURL: URL?
            var generatedAssetKind: ChatGeneratedAssetKind?
            var generationSummary = "\(plan.operationName) completed."
            var didComplete = false

            for await event in stream {
                if Task.isCancelled {
                    throw CancellationError()
                }

                switch event {
                case .progress(let message):
                    DiagnosticsLogStore.log(
                        "\(plan.operationName) status: \(message)",
                        category: .generation,
                        level: .debug
                    )
                    onUpdate(.progress(message))
                case .modelLoadProgress(let progress):
                    onUpdate(.modelLoadProgress(progress))
                case .generationProgress(let progress):
                    DiagnosticsLogStore.log(
                        "\(plan.operationName) progress \(progress.percentText ?? "")".trimmingCharacters(in: .whitespacesAndNewlines),
                        category: .generation,
                        level: .debug,
                        details: "Phase: \(progress.phase)\nMessage: \(progress.displayMessage)\nModel: \(progress.modelId)\nBackend: \(progress.backend.rawValue)"
                    )
                    onUpdate(.generationProgress(progress))
                case .image(let imageURL) where plan.attachmentKind == .image:
                    firstOutputAt = firstOutputAt ?? Date()
                    generatedAssetURL = imageURL
                    generatedAssetKind = .image
                case .audio(let audioURL) where plan.attachmentKind == .audio:
                    firstOutputAt = firstOutputAt ?? Date()
                    generatedAssetURL = audioURL
                    generatedAssetKind = .audio
                case .token(let token):
                    guard !token.isEmpty else { break }
                    firstOutputAt = firstOutputAt ?? Date()
                    observedTokenEvents += 1
                case .complete(let response, let usage):
                    didComplete = true
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
            try Task.checkCancellation()

            let metrics = GenerationPerformanceMetrics.measured(
                startedAt: startedAt,
                firstOutputAt: firstOutputAt,
                outputTokenCount: completionTokenCount > 0 ? completionTokenCount : observedTokenEvents,
                backendTokensPerSecond: backendTokensPerSecond
            )

            guard didComplete else {
                throw ExecutionError.processStopped("\(plan.operationName) stream ended before reporting completion.")
            }

            if let generatedAssetURL, let generatedAssetKind {
                onUpdate(.generatedAsset(generatedAssetURL, kind: generatedAssetKind))
                DiagnosticsLogStore.log(
                    "\(plan.operationName) completed",
                    category: .generation,
                    level: .info,
                    details: "Output: \(generatedAssetURL.path)\nDuration: \(String(format: "%.2f", metrics.totalDuration))s"
                )
                return .toolMessage("\(generationSummary)\n\(plan.completionHint)", metrics: metrics)
            }

            DiagnosticsLogStore.log(
                "\(plan.operationName) completed without an output asset",
                category: .generation,
                level: .warning,
                details: "Duration: \(String(format: "%.2f", metrics.totalDuration))s"
            )
            return .toolMessage(plan.noOutputMessage, metrics: metrics)
        } catch {
            throw error
        }
    }
}
