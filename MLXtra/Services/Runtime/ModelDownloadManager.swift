import Foundation
import Darwin

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

private enum DownloadStopReason: Equatable {
    case pause
    case cancel
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
    static let shared = ModelDownloadManager()
#if DEBUG
    static var terminationKillFallbackDelay: TimeInterval = 3.0
    static var terminationCleanupDelay: TimeInterval = 3.2
#else
    private static let terminationKillFallbackDelay: TimeInterval = 3.0
    private static let terminationCleanupDelay: TimeInterval = 3.2
#endif

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
            return Self.clampedPercent(percent) / 100.0
        }

        var displayText: String {
            if let percent {
                return "\(Int(Self.clampedPercent(percent).rounded()))%"
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

        private static func clampedPercent(_ percent: Double) -> Double {
            max(0.0, min(percent, 100.0))
        }
    }

    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(DownloadProgress?)
        case paused(DownloadProgress?)
        case downloaded
        case failed(String)

        var isDownloading: Bool {
            if case .downloading = self {
                return true
            }
            return false
        }

        var isPaused: Bool {
            if case .paused = self {
                return true
            }
            return false
        }

        var progress: DownloadProgress? {
            switch self {
            case .downloading(let progress), .paused(let progress):
                return progress
            case .notDownloaded, .downloaded, .failed:
                return nil
            }
        }

        var isTerminal: Bool {
            switch self {
            case .downloaded, .failed:
                return true
            case .notDownloaded, .downloading, .paused:
                return false
            }
        }

        var failureMessage: String? {
            if case .failed(let message) = self {
                return message
            }
            return nil
        }

        var isRepairableFailure: Bool {
            guard let message = failureMessage?.lowercased() else { return false }
            return message.contains("incomplete")
                || message.contains("not found in cache")
                || message.contains("missing files")
                || message.contains("missing components")
                || message.contains("redownload")
        }
    }

    @Published private(set) var states: [String: DownloadState] = [:]

    private let runtimeManager = RuntimeManager()
    private let checkpointsPathOverride: URL?
    private let huggingFaceCacheRootOverride: URL?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var processes: [String: Process] = [:]
    private var stopReasons: [String: DownloadStopReason] = [:]
    private var lastProgress: [String: DownloadProgress] = [:]
    private let errorTracker = DownloadErrorTracker()
#if DEBUG
    private let usesUITestDownloadStates: Bool
#endif

    init(
        refreshStatusesOnInit: Bool = true,
        checkpointsPathOverride: URL? = nil,
        huggingFaceCacheRootOverride: URL? = nil
    ) {
        self.checkpointsPathOverride = checkpointsPathOverride
        self.huggingFaceCacheRootOverride = huggingFaceCacheRootOverride
#if DEBUG
        usesUITestDownloadStates = ProcessInfo.processInfo.environment["MLXTRA_UI_TEST_DOWNLOAD_STATES"] == "1"
        if usesUITestDownloadStates {
            installUITestDownloadStates()
            return
        }
#endif
        if refreshStatusesOnInit {
            refreshStatuses()
        }
    }

    private var checkpointsPath: URL {
        checkpointsPathOverride ?? runtimeManager.checkpointsPath
    }

    private var huggingFaceCacheRoot: URL {
        huggingFaceCacheRootOverride ?? RuntimeManager.huggingFaceCacheRoot()
    }

    func refreshStatuses() {
#if DEBUG
        guard !usesUITestDownloadStates else { return }
#endif
        let modelsToCheck = DownloadableModel.embedded.compactMap { model -> DownloadableModel? in
            guard states[model.id]?.isDownloading != true,
                  states[model.id]?.isPaused != true else {
                return nil
            }
            return model
        }
        let checkpointsPath = self.checkpointsPath

        Task { [modelsToCheck, checkpointsPath] in
            let results = await Task.detached(priority: .utility) {
                modelsToCheck.map { model in
                    (
                        model.id,
                        RuntimeManager.modelStorageStatus(
                            model: model,
                            checkpointsPath: checkpointsPath
                        )
                    )
                }
            }.value

            for (modelId, status) in results
                where states[modelId]?.isDownloading != true && states[modelId]?.isPaused != true {
                states[modelId] = Self.downloadState(for: status)
            }
        }
    }

#if DEBUG
    private func installUITestDownloadStates() {
        let models = DownloadableModel.embedded
        let halfProgress = DownloadProgress(
            status: "Downloading",
            description: "UI test fixture",
            unit: "B",
            progressKind: "bytes",
            downloadedBytes: 512,
            totalBytes: 1024,
            percent: 50
        )
        let pausedProgress = DownloadProgress(
            status: "Paused",
            description: "UI test fixture",
            unit: "B",
            progressKind: "bytes",
            downloadedBytes: 256,
            totalBytes: 1024,
            percent: 25
        )

        let fixtures: [DownloadState] = [
            .downloaded,
            .notDownloaded,
            .downloading(halfProgress),
            .paused(pausedProgress),
            .failed("Incomplete cache: missing files. Redownload to repair."),
            .failed("Network unavailable.")
        ]

        for (model, state) in zip(models, fixtures) {
            states[model.id] = state
        }
    }
#endif

    func state(for model: DownloadableModel) -> DownloadState {
        states[model.id] ?? .notDownloaded
    }

    func cachePath(for model: DownloadableModel) -> String {
        Self.storageURLs(
            for: model,
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: huggingFaceCacheRoot
        )
        .first?
        .path ?? runtimeManager.modelStoragePath(for: model).path
    }

    func download(_ model: DownloadableModel) {
#if DEBUG
        guard !usesUITestDownloadStates else { return }
#endif
        guard tasks[model.id] == nil else { return }

        errorTracker.clearErrorReceived(for: model.id)
        stopReasons[model.id] = nil
        states[model.id] = .downloading(states[model.id]?.progress ?? lastProgress[model.id])
        tasks[model.id] = Task { [weak self] in
            guard let self else { return }

            do {
                try runtimeManager.validateDownloadSupport(for: model)
                if model.source.usesComponentBundle {
                    try await runAceStepDownload(model: model)
                } else {
                    try await runSnapshotDownload(model: model)
                }
                let storageStatus = await modelStorageStatusOffMain(model: model)
                states[model.id] = Self.downloadStateAfterDownload(for: storageStatus)
                if storageStatus.isDownloaded {
                    lastProgress[model.id] = nil
                }
            } catch {
                if let stopReason = stopReasons[model.id] {
                    switch stopReason {
                    case .pause:
                        states[model.id] = .paused(lastProgress[model.id])
                    case .cancel:
                        lastProgress[model.id] = nil
                        states[model.id] = .notDownloaded
                    }
                } else if !errorTracker.errorWasReceived(for: model.id) {
                    states[model.id] = .failed(error.localizedDescription)
                }
            }

            tasks[model.id] = nil
            processes[model.id] = nil
            stopReasons[model.id] = nil
        }
    }

    func pause(_ model: DownloadableModel) {
#if DEBUG
        guard !usesUITestDownloadStates else { return }
#endif
        stop(model, reason: .pause)
    }

    func resume(_ model: DownloadableModel) {
#if DEBUG
        guard !usesUITestDownloadStates else { return }
#endif
        download(model)
    }

    func cancel(_ model: DownloadableModel) {
#if DEBUG
        guard !usesUITestDownloadStates else { return }
#endif
        stop(model, reason: .cancel)
    }

    func remove(_ model: DownloadableModel) async {
#if DEBUG
        guard !usesUITestDownloadStates else {
            states[model.id] = .notDownloaded
            return
        }
#endif
        if states[model.id]?.isDownloading == true || states[model.id]?.isPaused == true {
            cancel(model)
        }

        let checkpointsPath = self.checkpointsPath
        let huggingFaceCacheRoot = self.huggingFaceCacheRoot
        do {
            try await Task.detached(priority: .utility) {
                try Self.removeLocalFiles(
                    for: model,
                    checkpointsPath: checkpointsPath,
                    huggingFaceCacheRoot: huggingFaceCacheRoot
                )
            }.value
            lastProgress[model.id] = nil
            states[model.id] = .notDownloaded
        } catch {
            states[model.id] = .failed(error.localizedDescription)
        }
    }

    nonisolated static func storageURLs(
        for model: DownloadableModel,
        checkpointsPath: URL,
        huggingFaceCacheRoot: URL = RuntimeManager.huggingFaceCacheRoot()
    ) -> [URL] {
        if model.source.usesComponentBundle {
            let components = model.source.components.isEmpty
                ? ModelSource.defaultSource(modelId: model.modelId).components
                : model.source.components
            return components.map { checkpointsPath.appendingPathComponent($0) }
        }

        return [
            RuntimeManager.modelCachePath(
                modelId: model.source.downloadRepository ?? model.modelId,
                huggingFaceCacheRoot: huggingFaceCacheRoot
            )
        ]
    }

    nonisolated static func removeLocalFiles(
        for model: DownloadableModel,
        checkpointsPath: URL,
        huggingFaceCacheRoot: URL = RuntimeManager.huggingFaceCacheRoot(),
        fileManager: FileManager = .default
    ) throws {
        for url in storageURLs(
            for: model,
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: huggingFaceCacheRoot
        ) where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func stop(_ model: DownloadableModel, reason: DownloadStopReason) {
        guard tasks[model.id] != nil else {
            if reason == .cancel {
                lastProgress[model.id] = nil
                states[model.id] = .notDownloaded
            }
            return
        }

        stopReasons[model.id] = reason
        switch reason {
        case .pause:
            states[model.id] = .paused(states[model.id]?.progress ?? lastProgress[model.id])
        case .cancel:
            lastProgress[model.id] = nil
            states[model.id] = .notDownloaded
        }

        if let process = processes[model.id] {
            if process.isRunning {
                tasks[model.id]?.cancel()
                process.terminate()
                // Schedule SIGKILL fallback after 3 seconds
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.terminationKillFallbackDelay) { [weak process] in
                    guard let process, process.isRunning else { return }
                    var zombieCheck: Int32 = 0
                    if waitpid(pid, &zombieCheck, WNOHANG) == 0 {
                        kill(pid, SIGKILL)
                    }
                }
                Task { @MainActor [weak self, weak process] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.terminationCleanupDelay * 1_000_000_000))
                    guard let self, let process, self.processes[model.id] === process, !process.isRunning else {
                        return
                    }
                    self.processes[model.id] = nil
                }
            }
            // Always clean up dictionary entries when process is not running,
            // even if terminationHandler hasn't fired yet
            if !process.isRunning {
                tasks[model.id]?.cancel()
                tasks[model.id] = nil
                processes[model.id] = nil
                stopReasons[model.id] = nil
            }
        } else {
            tasks[model.id]?.cancel()
            tasks[model.id] = nil
            stopReasons[model.id] = nil
        }
    }

#if DEBUG
    func installTestDownloadProcess(_ process: Process, for model: DownloadableModel) {
        let modelId = model.id
        states[model.id] = .downloading(nil)
        processes[model.id] = process
        tasks[model.id] = Task { [weak self, weak process] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.terminationCleanupDelay * 1_000_000_000))
            guard let self else { return }
            if self.tasks[modelId]?.isCancelled == true {
                self.tasks[modelId] = nil
            }
            if let process, self.processes[modelId] === process, !process.isRunning {
                self.processes[modelId] = nil
            }
            self.stopReasons[modelId] = nil
        }
    }

    func hasTrackedProcess(for model: DownloadableModel) -> Bool {
        processes[model.id] != nil
    }

    func hasTrackedTask(for model: DownloadableModel) -> Bool {
        tasks[model.id] != nil
    }
#endif

    private func isModelDownloadedOffMain(modelId: String) async -> Bool {
        let status = await modelStorageStatusOffMain(modelId: modelId)
        return status.isDownloaded
    }

    private func modelStorageStatusOffMain(modelId: String) async -> RuntimeManager.ModelStorageStatus {
        if let model = DownloadableModel.embeddedModel(modelId: modelId) {
            return await modelStorageStatusOffMain(model: model)
        }

        let checkpointsPath = runtimeManager.checkpointsPath
        return await Task.detached(priority: .utility) {
            RuntimeManager.modelStorageStatus(modelId: modelId, checkpointsPath: checkpointsPath)
        }.value
    }

    private func modelStorageStatusOffMain(model: DownloadableModel) async -> RuntimeManager.ModelStorageStatus {
        let checkpointsPath = runtimeManager.checkpointsPath
        return await Task.detached(priority: .utility) {
            RuntimeManager.modelStorageStatus(model: model, checkpointsPath: checkpointsPath)
        }.value
    }

    private static func downloadState(for storageStatus: RuntimeManager.ModelStorageStatus) -> DownloadState {
        switch storageStatus {
        case .downloaded:
            return .downloaded
        case .missing:
            return .notDownloaded
        case .incomplete(let message):
            return .failed(message)
        }
    }

    private static func downloadStateAfterDownload(for storageStatus: RuntimeManager.ModelStorageStatus) -> DownloadState {
        switch storageStatus {
        case .downloaded:
            return .downloaded
        case .missing:
            return .failed("Download finished, but model files were not found in cache.")
        case .incomplete(let message):
            return .failed(message)
        }
    }

    private func runAceStepDownload(model: DownloadableModel) async throws {
        let helperPath = runtimeManager.acestepDownloadHelperPath()
        let pythonPath = runtimeManager.acestepPythonExecutablePath()
        let localDir = runtimeManager.checkpointsPath.path
        let modelId = model.id
        let repoId = model.source.downloadRepository ?? model.modelId

        print("[ModelDownloadManager] Running ACE-Step download helper with Python at \(pythonPath.path)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let lineBuffer = DownloadLineBuffer()
            let outputLog = DownloadOutputLog()
            let errorLog = DownloadOutputLog()

            process.executableURL = pythonPath
            process.arguments = [helperPath.path, repoId, localDir]
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

            errorPipe.fileHandleForReading.readabilityHandler = { [weak errorLog] handle in
                let data = handle.availableData
                guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

                errorLog?.append(output)
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
                    guard let self else {
                        continuation.resume(throwing: ModelDownloadError.downloadFailed("Download manager was released."))
                        return
                    }

                    self.processes[modelId] = nil
                    self.handleDownloadEventLines(output, modelId: modelId)

                    if self.stopReasons[modelId] != nil {
                        continuation.resume(throwing: ModelDownloadError.stoppedByUser)
                        return
                    }

                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: ModelDownloadError.downloadFailed(output.isEmpty ? errorOutput : output))
                    }
                }
            }

            do {
                try process.run()
                processes[modelId] = process
            } catch {
                processes[modelId] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func runSnapshotDownload(model: DownloadableModel) async throws {
        let helperPath = runtimeManager.huggingFaceDownloadHelperPath()
        let pythonPath = runtimeManager.pythonExecutablePath()
        let modelId = model.id
        let repoId = model.source.downloadRepository ?? model.modelId

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let lineBuffer = DownloadLineBuffer()
            let outputLog = DownloadOutputLog()
            let errorLog = DownloadOutputLog()

            process.executableURL = pythonPath
            process.arguments = [helperPath.path, repoId]

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

            errorPipe.fileHandleForReading.readabilityHandler = { [weak errorLog] handle in
                let data = handle.availableData
                guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

                errorLog?.append(output)
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
                    guard let self else {
                        continuation.resume(throwing: ModelDownloadError.downloadFailed("Download manager was released."))
                        return
                    }

                    self.processes[modelId] = nil
                    self.handleDownloadEventLines(output, modelId: modelId)

                    if self.stopReasons[modelId] != nil {
                        continuation.resume(throwing: ModelDownloadError.stoppedByUser)
                        return
                    }

                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: ModelDownloadError.downloadFailed(errorOutput.isEmpty ? "huggingface_hub exited with status \(process.terminationStatus)" : errorOutput))
                    }
                }
            }

            do {
                try process.run()
                processes[modelId] = process
            } catch {
                processes[modelId] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func handleDownloadEventLines(_ output: String, modelId: String) {
        for line in output.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }
            handleDownloadEventLine(trimmedLine, modelId: modelId)
        }
    }

    func handleDownloadEventLine(_ line: String, modelId: String) {
        guard stopReasons[modelId] == nil else { return }

        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else {
            return
        }

        switch type {
        case "download.started":
            guard states[modelId]?.isTerminal != true else { return }
            let progress = DownloadProgress(
                status: "Preparing",
                description: nil,
                unit: nil,
                progressKind: nil,
                downloadedBytes: nil,
                totalBytes: nil,
                percent: nil
            )
            lastProgress[modelId] = progress
            states[modelId] = .downloading(progress)
        case "download.progress":
            guard states[modelId]?.isTerminal != true else { return }
            let progressKind = event["progress_kind"] as? String
            let percent = Self.monotonicPercent(
                Self.reliableDownloadPercent(from: event, progressKind: progressKind),
                previous: lastProgress[modelId]?.percent
            )
            let progress = DownloadProgress(
                status: event["status"] as? String ?? "Downloading",
                description: event["description"] as? String,
                unit: event["unit"] as? String,
                progressKind: progressKind,
                downloadedBytes: Self.int64Value(event["downloaded"]),
                totalBytes: Self.int64Value(event["total"]),
                percent: percent
            )
            lastProgress[modelId] = progress
            states[modelId] = .downloading(progress)
        case "download.verified":
            guard states[modelId]?.isTerminal != true else { return }
            let hashCount = Self.int64Value(event["hash_count"]) ?? 0
            let progress = DownloadProgress(
                status: "Verifying",
                description: hashCount > 0 ? "Local files and hashes verified" : "Local files verified",
                unit: nil,
                progressKind: nil,
                downloadedBytes: nil,
                totalBytes: nil,
                percent: nil
            )
            lastProgress[modelId] = progress
            states[modelId] = .downloading(progress)
        case "download.complete":
            guard states[modelId]?.isTerminal != true else { return }
            let progress = DownloadProgress(
                status: "Finalizing",
                description: nil,
                unit: nil,
                progressKind: nil,
                downloadedBytes: nil,
                totalBytes: nil,
                percent: nil
            )
            lastProgress[modelId] = progress
            states[modelId] = .downloading(progress)
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

    nonisolated static func reliableDownloadPercent(from event: [String: Any], progressKind: String?) -> Double? {
        guard let percent = doubleValue(event["percent"]) else { return nil }

        let isReliable = boolValue(event["percent_reliable"]) == true
            || (progressKind == "bytes" && event["progress_scope"] as? String == "aggregate")
        return isReliable ? clampedPercent(percent) : nil
    }

    private nonisolated static func monotonicPercent(_ percent: Double?, previous: Double?) -> Double? {
        guard let percent else { return nil }
        guard let previous else { return percent }
        return max(percent, previous)
    }

    private nonisolated static func clampedPercent(_ percent: Double) -> Double {
        max(0.0, min(percent, 100.0))
    }

    private nonisolated static func int64Value(_ value: Any?) -> Int64? {
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

    private nonisolated static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    private nonisolated static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
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
    case stoppedByUser

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let message):
            return message
        case .stoppedByUser:
            return "Download stopped."
        }
    }
}
