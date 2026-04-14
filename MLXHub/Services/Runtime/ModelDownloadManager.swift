import Foundation

@MainActor
final class ModelDownloadManager: ObservableObject {
    enum DownloadState: Equatable {
        case notDownloaded
        case downloading
        case downloaded
        case failed(String)

        var isDownloading: Bool {
            if case .downloading = self {
                return true
            }
            return false
        }
    }

    @Published private(set) var states: [String: DownloadState] = [:]

    private let runtimeManager = RuntimeManager()
    private var tasks: [String: Task<Void, Never>] = [:]

    init() {
        refreshStatuses()
    }

    func refreshStatuses() {
        for model in DownloadableModel.embedded {
            if states[model.id]?.isDownloading == true {
                continue
            }

            states[model.id] = runtimeManager.isModelDownloaded(modelId: model.modelId) ? .downloaded : .notDownloaded
        }
    }

    func state(for model: DownloadableModel) -> DownloadState {
        states[model.id] ?? (runtimeManager.isModelDownloaded(modelId: model.modelId) ? .downloaded : .notDownloaded)
    }

    func cachePath(for model: DownloadableModel) -> String {
        runtimeManager.modelCachePath(modelId: model.modelId).path
    }

    func download(_ model: DownloadableModel) {
        guard tasks[model.id] == nil else { return }

        states[model.id] = .downloading
        tasks[model.id] = Task { [weak self] in
            guard let self else { return }

            do {
                try await runtimeManager.initialize()
                if model.modelId.hasPrefix("ACE-Step/") {
                    try await runAceStepDownload(modelId: model.modelId)
                } else {
                    try await runSnapshotDownload(modelId: model.modelId)
                }
                states[model.id] = runtimeManager.isModelDownloaded(modelId: model.modelId) ? .downloaded : .failed("Download finished, but model files were not found in cache.")
            } catch {
                states[model.id] = .failed(error.localizedDescription)
            }

            tasks[model.id] = nil
        }
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

            process.executableURL = pythonPath
            process.arguments = [helperPath.path, modelId, localDir]
            process.environment = [
                "ACESTEP_CHECKPOINTS_DIR": localDir,
                "HF_HOME": FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface").path,
                "HF_HUB_CACHE": FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub").path,
            ]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { process in
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

                print("[ModelDownloadManager] ACE-Step helper output: \(output.prefix(500))")
                if !errorOutput.isEmpty {
                    print("[ModelDownloadManager] ACE-Step helper stderr: \(errorOutput.prefix(500))")
                }

                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ModelDownloadError.downloadFailed(output.isEmpty ? errorOutput : output))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private var checkpointsPath: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MLXHub")
            .appendingPathComponent("checkpoints")
    }

    private func runSnapshotDownload(modelId: String) async throws {
        let modelName = modelId.replacingOccurrences(of: "/", with: "--")
        let localDir = checkpointsPath.appendingPathComponent(modelName).path
        let pythonCode = """
import sys
from huggingface_hub import snapshot_download
snapshot_download(repo_id=sys.argv[1], local_dir=sys.argv[2])
"""

        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()

process.executableURL = runtimeManager.pythonExecutablePath()
        process.arguments = ["-c", pythonCode, modelId, localDir]
            process.environment = ProcessInfo.processInfo.environment.merging([
                "HF_HOME": FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface").path,
                "HF_HUB_CACHE": FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub").path,
            ]) { _, new in new }
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            process.terminationHandler = { process in
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ModelDownloadError.downloadFailed(output ?? "huggingface_hub exited with status \(process.terminationStatus)"))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
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
