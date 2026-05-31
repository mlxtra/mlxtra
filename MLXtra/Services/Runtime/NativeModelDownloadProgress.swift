import Foundation

struct NativeModelDownloadProgress: Equatable {
    let status: String
    let description: String?
    let downloadedBytes: Int64?
    let totalBytes: Int64?
    let percent: Double?
}

actor NativeDownloadProgressAggregator {
    private var completedBytes: Int64
    private var activeFileBytes: [String: Int64] = [:]
    private var completedFileIDs: Set<String> = []
    private var lastEmittedBytes: Int64
    private var lastEmissionDate: Date?
    private let totalBytes: Int64?
    private let progress: NativeModelDownloadService.ProgressHandler
    private let minimumEmitInterval: TimeInterval

    init(
        completedBytes: Int64,
        totalBytes: Int64?,
        progress: @escaping NativeModelDownloadService.ProgressHandler,
        minimumEmitInterval: TimeInterval = 0
    ) {
        self.completedBytes = completedBytes
        self.lastEmittedBytes = completedBytes
        self.totalBytes = totalBytes
        self.progress = progress
        self.minimumEmitInterval = max(0, minimumEmitInterval)
    }

    func updateActiveBytes(fileID: String, bytesWritten: Int64, description: String?) async {
        guard !completedFileIDs.contains(fileID) else { return }
        activeFileBytes[fileID] = max(0, bytesWritten)
        await emit(status: "Downloading", description: description)
    }

    func completeFile(fileID: String, completedBytes fileBytes: Int64, description: String?) async {
        activeFileBytes[fileID] = nil
        completedFileIDs.insert(fileID)
        completedBytes += max(0, fileBytes)
        await emit(status: "Downloading", description: description, force: true)
    }

    private func emit(status: String, description: String?, force: Bool = false) async {
        let now = Date()
        if !force,
           minimumEmitInterval > 0,
           let lastEmissionDate,
           now.timeIntervalSince(lastEmissionDate) < minimumEmitInterval {
            return
        }

        let activeBytes = activeFileBytes.values.reduce(Int64(0), +)
        let rawDownloadedBytes = completedBytes + activeBytes
        let downloadedBytes = max(rawDownloadedBytes, lastEmittedBytes)
        lastEmittedBytes = downloadedBytes
        lastEmissionDate = now
        await progress(
            NativeModelDownloadProgress(
                status: status,
                description: description,
                downloadedBytes: downloadedBytes,
                totalBytes: totalBytes,
                percent: NativeModelDownloadService.percent(downloaded: downloadedBytes, total: totalBytes)
            )
        )
    }
}
