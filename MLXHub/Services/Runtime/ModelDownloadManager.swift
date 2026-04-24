import Foundation

private final class DownloadLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ text: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        buffer += text
        let lines = buffer.components(separatedBy: .newlines)
        buffer = lines.last ?? ""
        return Array(lines.dropLast())
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }

        let remaining = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return remaining.isEmpty ? nil : remaining
    }
}

private final class DownloadOutputLog: @unchecked Sendable {
	private let lock = NSLock()
	private var text = ""
    private let maxCharacters: Int

    init(maxCharacters: Int = 40_000) {
        self.maxCharacters = maxCharacters
    }

	func append(_ newText: String) {
		lock.lock()
		defer { lock.unlock() }
		text += newText
        if text.count > maxCharacters {
            text = String(text.suffix(maxCharacters))
        }
	}

	func value() -> String {
		lock.lock()
		defer { lock.unlock() }
		return text
	}
}

final class DownloadErrorTracker: @unchecked Sendable {
	private let lock = NSLock()
	private var receivedError: [String: Bool] = [:]

	func setErrorReceived(for modelId: String) {
		lock.lock()
		defer { lock.unlock() }
		receivedError[modelId] = true
	}

	func clearErrorReceived(for modelId: String) {
		lock.lock()
		defer { lock.unlock() }
		receivedError[modelId] = nil
	}

	func errorWasReceived(for modelId: String) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		return receivedError[modelId] ?? false
	}
}

@MainActor
final class ModelDownloadManager: ObservableObject {
    struct DownloadProgress: Equatable {
        let status: String
        let description: String?
        let unit: String?
        let progressKind: String?
        let downloadedBytes: Int64?
        let totalBytes: Int64?
        let percent: Double?

        var fractionCompleted: Double? {
            guard let percent else { return nil }
            return max(0.0, min(percent / 100.0, 1.0))
        }

        var displayText: String {
            if let percent {
                return "\(Int(percent.rounded()))%"
            }
            return status
        }

        var detailText: String? {
            if let downloadedBytes, let totalBytes, totalBytes > 0 {
                if isByteProgress {
                    return "\(Self.formatBytes(downloadedBytes)) of \(Self.formatBytes(totalBytes))"
                }

                if isFileProgress {
                    return "\(downloadedBytes) of \(totalBytes) \(totalBytes == 1 ? "file" : "files")"
                }

                if let unit, !unit.isEmpty {
                    return "\(downloadedBytes) of \(totalBytes) \(Self.displayUnit(unit, total: totalBytes))"
                }
            }

            guard let description, !description.isEmpty else {
                return nil
            }
            return description
        }

        private var isByteProgress: Bool {
            progressKind == "bytes" || unit == "B"
        }

        private var isFileProgress: Bool {
            progressKind == "files" || unit == "it" || unit == "file" || unit == "files"
        }

        private static func formatBytes(_ bytes: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: bytes)
        }

        private static func displayUnit(_ unit: String, total: Int64) -> String {
            if unit == "it" {
                return total == 1 ? "item" : "items"
            }
            return unit
        }
    }

    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(DownloadProgress?)
        case downloaded
        case failed(String)

        var isDownloading: Bool {
            if case .downloading = self {
                return true
            }
            return false
        }

        var isTerminal: Bool {
            switch self {
            case .downloaded, .failed:
                return true
            case .notDownloaded, .downloading:
                return false
            }
        }
    }

@Published private(set) var states: [String: DownloadState] = [:]

	private let runtimeManager = RuntimeManager()
	private var tasks: [String: Task<Void, Never>] = [:]
	private let errorTracker = DownloadErrorTracker()

    init() {
        refreshStatuses()
    }

    func refreshStatuses() {
        let modelsToCheck = DownloadableModel.embedded.compactMap { model -> (id: String, modelId: String)? in
            guard states[model.id]?.isDownloading != true else {
                return nil
            }
            return (model.id, model.modelId)
        }
        let checkpointsPath = runtimeManager.checkpointsPath

        Task { [modelsToCheck, checkpointsPath] in
            let results = await Task.detached(priority: .utility) {
                modelsToCheck.map { model in
                    (model.id, RuntimeManager.isModelDownloaded(modelId: model.modelId, checkpointsPath: checkpointsPath))
                }
            }.value

            for (modelId, isDownloaded) in results where states[modelId]?.isDownloading != true {
                states[modelId] = isDownloaded ? .downloaded : .notDownloaded
            }
        }
    }

    func state(for model: DownloadableModel) -> DownloadState {
        states[model.id] ?? .notDownloaded
    }

    func cachePath(for model: DownloadableModel) -> String {
        runtimeManager.modelStoragePath(modelId: model.modelId).path
    }

    func download(_ model: DownloadableModel) {
        guard tasks[model.id] == nil else { return }

        errorTracker.clearErrorReceived(for: model.id)
        states[model.id] = .downloading(nil)
        tasks[model.id] = Task { [weak self] in
            guard let self else { return }

            do {
                try runtimeManager.validateDownloadSupport(for: model.modelId)
                if model.modelId.hasPrefix("ACE-Step/") {
                    try await runAceStepDownload(modelId: model.modelId)
                } else {
                    try await runSnapshotDownload(modelId: model.modelId)
                }
                let isDownloaded = await isModelDownloadedOffMain(modelId: model.modelId)
                states[model.id] = isDownloaded ? .downloaded : .failed("Download finished, but model files were not found in cache.")
            } catch {
                if !errorTracker.errorWasReceived(for: model.id) {
                    states[model.id] = .failed(error.localizedDescription)
                }
            }

            tasks[model.id] = nil
        }
    }

    private func isModelDownloadedOffMain(modelId: String) async -> Bool {
        let checkpointsPath = runtimeManager.checkpointsPath
        return await Task.detached(priority: .utility) {
            RuntimeManager.isModelDownloaded(modelId: modelId, checkpointsPath: checkpointsPath)
        }.value
    }

    private func runAceStepDownload(modelId: String) async throws {
        let helperPath = runtimeManager.acestepDownloadHelperPath()
        let pythonPath = runtimeManager.acestepPythonExecutablePath()
        let localDir = runtimeManager.checkpointsPath.path

        print("[ModelDownloadManager] Running ACE-Step download helper with Python at \(pythonPath.path)")

        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let lineBuffer = DownloadLineBuffer()
            let outputLog = DownloadOutputLog()
            let errorLog = DownloadOutputLog()

            process.executableURL = pythonPath
            process.arguments = [helperPath.path, modelId, localDir]
            var downloadEnv = bundledPythonEnvironment()
            downloadEnv["ACESTEP_CHECKPOINTS_DIR"] = localDir
            process.environment = downloadEnv
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

                outputLog.append(output)
                for line in lineBuffer.append(output) {
                    Task { @MainActor [weak self] in
                        self?.handleDownloadEventLine(line, modelId: modelId)
                    }
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

                errorLog.append(output)
            }

            process.terminationHandler = { process in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                let trailingData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if !trailingData.isEmpty, let trailingOutput = String(data: trailingData, encoding: .utf8) {
                    outputLog.append(trailingOutput)
                    for line in lineBuffer.append(trailingOutput) {
                        Task { @MainActor [weak self] in
                            self?.handleDownloadEventLine(line, modelId: modelId)
                        }
                    }
                }

                if let remainingLine = lineBuffer.flush() {
                    Task { @MainActor [weak self] in
                        self?.handleDownloadEventLine(remainingLine, modelId: modelId)
                    }
                }

                let errorTrailingData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                if !errorTrailingData.isEmpty, let trailingErrorOutput = String(data: errorTrailingData, encoding: .utf8) {
                    errorLog.append(trailingErrorOutput)
                }

                let output = outputLog.value()
                let errorOutput = errorLog.value()

                print("[ModelDownloadManager] ACE-Step helper output: \(output.prefix(500))")
                if !errorOutput.isEmpty {
                    print("[ModelDownloadManager] ACE-Step helper stderr: \(errorOutput.prefix(500))")
                }

                Task { @MainActor [weak self] in
                    self?.handleDownloadEventLines(output, modelId: modelId)

                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: ModelDownloadError.downloadFailed(output.isEmpty ? errorOutput : output))
                    }
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func runSnapshotDownload(modelId: String) async throws {
        let helperPath = runtimeManager.huggingFaceDownloadHelperPath()
        let pythonPath = runtimeManager.pythonExecutablePath()

        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let lineBuffer = DownloadLineBuffer()
            let outputLog = DownloadOutputLog()
            let errorLog = DownloadOutputLog()

            process.executableURL = pythonPath
            process.arguments = [helperPath.path, modelId]

            process.environment = bundledPythonEnvironment()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

                outputLog.append(output)
                for line in lineBuffer.append(output) {
                    Task { @MainActor [weak self] in
                        self?.handleDownloadEventLine(line, modelId: modelId)
                    }
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

                errorLog.append(output)
            }

            process.terminationHandler = { process in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                let trailingData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if !trailingData.isEmpty, let trailingOutput = String(data: trailingData, encoding: .utf8) {
                    outputLog.append(trailingOutput)
                    for line in lineBuffer.append(trailingOutput) {
                        Task { @MainActor [weak self] in
                            self?.handleDownloadEventLine(line, modelId: modelId)
                        }
                    }
                }

                if let remainingLine = lineBuffer.flush() {
                    Task { @MainActor [weak self] in
                        self?.handleDownloadEventLine(remainingLine, modelId: modelId)
                    }
                }

                let errorTrailingData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                if !errorTrailingData.isEmpty, let trailingErrorOutput = String(data: errorTrailingData, encoding: .utf8) {
                    errorLog.append(trailingErrorOutput)
                }

                let output = outputLog.value()
                let errorOutput = errorLog.value()
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                Task { @MainActor [weak self] in
                    self?.handleDownloadEventLines(output, modelId: modelId)

                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: ModelDownloadError.downloadFailed(errorOutput.isEmpty ? "huggingface_hub exited with status \(process.terminationStatus)" : errorOutput))
                    }
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func handleDownloadEventLines(_ output: String, modelId: String) {
        for line in output.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }
            handleDownloadEventLine(trimmedLine, modelId: modelId)
        }
    }

    private func handleDownloadEventLine(_ line: String, modelId: String) {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else {
            return
        }

        switch type {
        case "download.started":
            guard states[modelId]?.isTerminal != true else { return }
            states[modelId] = .downloading(DownloadProgress(
                status: "Preparing",
                description: nil,
                unit: nil,
                progressKind: nil,
                downloadedBytes: nil,
                totalBytes: nil,
                percent: nil
            ))
        case "download.progress":
            guard states[modelId]?.isTerminal != true else { return }
            states[modelId] = .downloading(DownloadProgress(
                status: event["status"] as? String ?? "Downloading",
                description: event["description"] as? String,
                unit: event["unit"] as? String,
                progressKind: event["progress_kind"] as? String,
                downloadedBytes: Self.int64Value(event["downloaded"]),
                totalBytes: Self.int64Value(event["total"]),
                percent: event["percent"] as? Double
            ))
        case "download.complete":
            guard states[modelId]?.isTerminal != true else { return }
            states[modelId] = .downloading(DownloadProgress(
                status: "Verifying",
                description: nil,
                unit: nil,
                progressKind: nil,
                downloadedBytes: nil,
                totalBytes: nil,
                percent: nil
            ))
        case "download.error":
            guard states[modelId] != .downloaded else { return }
            if let message = event["message"] as? String {
                errorTracker.setErrorReceived(for: modelId)
                states[modelId] = .failed(message)
            }
        default:
            break
        }
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? Double {
            return Int64(value)
        }
        return nil
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

enum ModelDownloadError: LocalizedError {
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let message):
            return message
        }
    }
}
