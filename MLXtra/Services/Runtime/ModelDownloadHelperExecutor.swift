import Foundation

@MainActor
final class ModelDownloadHelperExecutor {
    typealias ProcessRunner = @MainActor (
        _ executableURL: URL,
        _ arguments: [String],
        _ environment: [String: String],
        _ onProcessStarted: @escaping @MainActor (Process) -> Void
    ) async throws -> DownloadHelperProcessResult

    private let runtimeManager: RuntimeManager
    private let lifecycle: ModelDownloadLifecycle
    private let processRunner: ProcessRunner

    init(
        runtimeManager: RuntimeManager,
        lifecycle: ModelDownloadLifecycle,
        processRunner: @escaping ProcessRunner = DownloadHelperProcessRunner.run
    ) {
        self.runtimeManager = runtimeManager
        self.lifecycle = lifecycle
        self.processRunner = processRunner
    }

    func runAceStepContractValidation(
        plan: AceStepDownloadPlan,
        modelId: String,
        onOutputLine: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        let helperPath = runtimeManager.acestepDownloadHelperPath()
        let pythonPath = runtimeManager.acestepPythonExecutablePath()
        let localDir = plan.checkpointsRoot.path

        DownloadDiagnostics.log("[ModelDownloadManager] Running ACE-Step contract validation with Python at \(pythonPath.path)")

        var downloadEnv = bundledPythonEnvironment()
        downloadEnv["ACESTEP_CHECKPOINTS_DIR"] = localDir

        let result = try await runDownloadHelper(
            modelId: modelId,
            executableURL: pythonPath,
            arguments: [helperPath.path, "--contract", localDir],
            environment: downloadEnv
        )

        DownloadDiagnostics.log("[ModelDownloadManager] ACE-Step contract output: \(result.output.prefix(500))")
        if !result.errorOutput.isEmpty {
            DownloadDiagnostics.log("[ModelDownloadManager] ACE-Step contract stderr: \(result.errorOutput.prefix(500))")
        }

        try finishDownloadHelperRun(
            result,
            modelId: modelId,
            failureMessage: result.output.isEmpty ? result.errorOutput : result.output,
            onOutputLine: onOutputLine
        )
    }

    private func runDownloadHelper(
        modelId: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> DownloadHelperProcessResult {
        do {
            return try await processRunner(
                executableURL,
                arguments,
                environment,
                { [lifecycle] process in
                    lifecycle.setProcess(process, for: modelId)
                }
            )
        } catch {
            lifecycle.clearProcess(for: modelId)
            throw error
        }
    }

    private func finishDownloadHelperRun(
        _ result: DownloadHelperProcessResult,
        modelId: String,
        failureMessage: String,
        onOutputLine: @escaping @MainActor @Sendable (String) -> Void
    ) throws {
        lifecycle.clearProcess(for: modelId)
        emitDownloadEventLines(result.output, onOutputLine: onOutputLine)

        if lifecycle.stopReason(for: modelId) != nil {
            throw ModelDownloadError.stoppedByUser
        }

        guard result.terminationStatus == 0 else {
            throw ModelDownloadError.downloadFailed(failureMessage)
        }
    }

    private func emitDownloadEventLines(
        _ output: String,
        onOutputLine: @escaping @MainActor @Sendable (String) -> Void
    ) {
        for line in output.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }
            onOutputLine(trimmedLine)
        }
    }

    private func bundledPythonEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["PYTHONPATH", "VIRTUAL_ENV", "CONDA_PREFIX", "CONDA_DEFAULT_ENV", "PYENV_ROOT", "PYENV_VERSION"] {
            environment.removeValue(forKey: key)
        }
        environment["PYTHONHOME"] = runtimeManager.pythonHomePath().path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["HF_HOME"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface").path
        environment["HF_HUB_CACHE"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub").path
        return environment
    }
}
