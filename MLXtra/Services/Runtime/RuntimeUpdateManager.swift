import Foundation
import Combine

@MainActor
final class RuntimeUpdateManager: ObservableObject {
    static let shared = RuntimeUpdateManager()

    enum InstallState: Equatable {
        case idle
        case checking
        case available(RuntimeReleaseAsset)
        case requiresAppUpdate(RuntimeAppUpdateRequirement)
        case installing(Double?)
        case installed(String)
        case failed(String)
    }

    @Published private(set) var state: InstallState = .idle
    @Published private(set) var channel: ReleaseChannelManifest?
    @Published private(set) var newerRuntimeRequiringAppUpdate: RuntimeAppUpdateRequirement?
    @Published private(set) var installingRuntime: RuntimeReleaseAsset?
    @Published private(set) var installPhase: RuntimeInstallPhase = .idle
    @Published private(set) var runtimeDownloadProgress: RuntimeDownloadProgress?
    @Published private(set) var runtimeActivationProgress: RuntimeActivationProgress?

    private let currentManifestProvider: () -> RuntimeManifest?
    private let appVersionProvider: () -> String?
    private let runtimeArchiveInstaller: RuntimeArchiveInstaller
    private let runtimeArchiveDownloadConfiguration: URLSessionConfiguration
    private let runtimeArchiveCacheDirectory: URL
    private var backgroundTask: Task<Void, Never>?
    private var runtimeDownloadSpeedSamples: [(date: Date, bytes: Int64)] = []

    init(
        currentManifestProvider: @escaping () -> RuntimeManifest? = { RuntimeManager.activeRuntimeManifest() },
        appVersionProvider: @escaping () -> String? = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        },
        runtimeArchiveInstaller: @escaping RuntimeArchiveInstaller = { archiveURL, progressHandler in
            try RuntimeManager.installRuntimeArchive(archiveURL, progressHandler: progressHandler)
        },
        runtimeArchiveDownloadConfiguration: URLSessionConfiguration = .default,
        runtimeArchiveCacheDirectory: URL = RuntimeManager.appSupportURL()
            .appendingPathComponent("downloads")
            .appendingPathComponent("runtime")
    ) {
        self.currentManifestProvider = currentManifestProvider
        self.appVersionProvider = appVersionProvider
        self.runtimeArchiveInstaller = runtimeArchiveInstaller
        self.runtimeArchiveDownloadConfiguration = runtimeArchiveDownloadConfiguration
        self.runtimeArchiveCacheDirectory = runtimeArchiveCacheDirectory
    }

    var availableRuntime: RuntimeReleaseAsset? {
        if case .available(let asset) = state {
            return asset
        }
        return nil
    }

    func bootstrapStableRuntimeInBackground(
        channelURL: URL = ReleaseChannelManifest.defaultChannelURL,
        reportFailures: Bool = false
    ) {
        startBackgroundTask {
            await $0.bootstrapStableRuntimeIfNeeded(channelURL: channelURL, reportFailures: reportFailures)
        }
    }

    func installRuntimeInBackground(_ asset: RuntimeReleaseAsset) {
        startBackgroundTask {
            await $0.installRuntime(asset)
        }
    }

    func bootstrapStableRuntimeIfNeeded(
        channelURL: URL = ReleaseChannelManifest.defaultChannelURL,
        reportFailures: Bool = false
    ) async {
        switch state {
        case .checking, .installing:
            return
        default:
            break
        }

        await refreshStableChannel(channelURL: channelURL, reportFailures: reportFailures)
        if case .available(let asset) = state {
            await installRuntime(asset)
        }
    }

    func refreshStableChannel(
        channelURL: URL = ReleaseChannelManifest.defaultChannelURL,
        reportFailures: Bool = true
    ) async {
        state = .checking
        newerRuntimeRequiringAppUpdate = nil
        do {
            let (data, response) = try await URLSession.shared.data(from: channelURL)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw RuntimeUpdateError.channelUnavailable
            }

            let manifest = try JSONDecoder().decode(ReleaseChannelManifest.self, from: data)
            channel = manifest

            let selection = runtimeUpdateSelection(in: manifest)
            newerRuntimeRequiringAppUpdate = selection.newerRuntimeRequiringAppUpdate

            if let asset = selection.compatibleRuntime {
                state = .available(asset)
            } else if let requirement = selection.newerRuntimeRequiringAppUpdate {
                state = .requiresAppUpdate(requirement)
            } else {
                state = .idle
            }
        } catch is CancellationError {
            state = .idle
        } catch {
            state = reportFailures ? .failed(error.localizedDescription) : .idle
        }
    }

    func installRuntime(_ asset: RuntimeReleaseAsset) async {
        if case .installing = state {
            return
        }

        installingRuntime = asset
        installPhase = .downloading
        resetRuntimeDownloadMetrics()
        runtimeDownloadProgress = asset.url.isFileURL
            ? nil
            : RuntimeDownloadProgress(downloadedBytes: 0, totalBytes: asset.sizeBytes)
        state = asset.url.isFileURL || asset.sizeBytes == nil ? .installing(nil) : .installing(0)
        do {
            let archiveURL = try await fetchRuntimeArchive(asset)
            let expectedSHA256 = asset.sha256
            installPhase = .verifying
            state = .installing(nil)
            let actualChecksum = try await Task.detached(priority: .utility) {
                try SHA256Checksum.hexDigest(for: archiveURL)
            }.value
            guard actualChecksum.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                try? FileManager.default.removeItem(at: archiveURL)
                throw RuntimeUpdateError.checksumMismatch
            }

            installPhase = .activating
            runtimeActivationProgress = RuntimeActivationProgress(
                title: "Preparing local files",
                detail: "Staging the runtime installer.",
                completedStep: 1,
                totalSteps: 5
            )
            let installer = runtimeArchiveInstaller
            let installedURL = try await Task.detached(priority: .utility) {
                try installer(archiveURL) { progress in
                    Task { @MainActor [weak self] in
                        self?.updateRuntimeActivationProgress(progress)
                    }
                }
            }.value
            guard let manifest = RuntimeManager.runtimeManifest(at: installedURL) else {
                throw RuntimeUpdateError.invalidRuntime
            }
            let runtimeVersion = manifest.runtimeVersion
            installPhase = .idle
            runtimeDownloadProgress = nil
            runtimeActivationProgress = nil
            resetRuntimeDownloadMetrics()
            state = .installed(runtimeVersion)
            installingRuntime = nil
        } catch is CancellationError {
            installPhase = .idle
            runtimeDownloadProgress = nil
            runtimeActivationProgress = nil
            resetRuntimeDownloadMetrics()
            state = .idle
            installingRuntime = nil
        } catch {
            installPhase = .idle
            runtimeDownloadProgress = nil
            runtimeActivationProgress = nil
            resetRuntimeDownloadMetrics()
            state = .failed(error.localizedDescription)
            installingRuntime = nil
        }
    }

    private func updateRuntimeActivationProgress(_ progress: RuntimeActivationProgress) {
        guard case .installing = state, installPhase == .activating else {
            return
        }
        runtimeActivationProgress = progress
        state = .installing(progress.fractionCompleted)
    }

    private func updateRuntimeDownloadProgress(_ progress: RuntimeDownloadProgress) {
        guard case .installing = state, installPhase == .downloading else {
            return
        }

        let now = Date()
        let bytesPerSecond = measuredRuntimeDownloadSpeed(for: progress, at: now)
        let measuredProgress = RuntimeDownloadProgress(
            downloadedBytes: progress.downloadedBytes,
            totalBytes: progress.totalBytes,
            bytesPerSecond: bytesPerSecond
        )
        runtimeDownloadProgress = measuredProgress
        state = .installing(measuredProgress.fractionCompleted)
    }

    private func measuredRuntimeDownloadSpeed(
        for progress: RuntimeDownloadProgress,
        at date: Date
    ) -> Double? {
        let downloadedBytes = progress.downloadedBytes
        if let lastSample = runtimeDownloadSpeedSamples.last {
            if downloadedBytes < lastSample.bytes || date.timeIntervalSince(lastSample.date) > 12 {
                runtimeDownloadSpeedSamples.removeAll()
            }
        }

        if runtimeDownloadSpeedSamples.last?.bytes != downloadedBytes {
            runtimeDownloadSpeedSamples.append((date, downloadedBytes))
        }

        let cutoff = date.addingTimeInterval(-8)
        while runtimeDownloadSpeedSamples.count > 2,
              let secondSample = runtimeDownloadSpeedSamples.dropFirst().first,
              secondSample.date < cutoff {
            runtimeDownloadSpeedSamples.removeFirst()
        }

        guard let firstSample = runtimeDownloadSpeedSamples.first,
              let lastSample = runtimeDownloadSpeedSamples.last,
              lastSample.bytes > firstSample.bytes else {
            return nil
        }

        let seconds = lastSample.date.timeIntervalSince(firstSample.date)
        guard seconds >= 0.05 else { return nil }
        return Double(lastSample.bytes - firstSample.bytes) / seconds
    }

    private func resetRuntimeDownloadMetrics() {
        runtimeDownloadSpeedSamples.removeAll()
    }

    private func startBackgroundTask(_ operation: @escaping @MainActor (RuntimeUpdateManager) async -> Void) {
        if let backgroundTask, !backgroundTask.isCancelled {
            return
        }

        switch state {
        case .checking, .installing:
            return
        default:
            break
        }

        backgroundTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await operation(self)
            self.backgroundTask = nil
        }
    }

    private struct RuntimeUpdateSelection {
        let compatibleRuntime: RuntimeReleaseAsset?
        let newerRuntimeRequiringAppUpdate: RuntimeAppUpdateRequirement?
    }

    private func runtimeUpdateSelection(in manifest: ReleaseChannelManifest) -> RuntimeUpdateSelection {
        let current = currentManifestProvider()
        let candidates = manifest.runtimes
            .filter { $0.platform == "macos" && $0.arch == "arm64" }
            .filter { asset in
                guard let current else { return true }
                guard asset.compatibilityApi == current.compatibilityApi else { return false }
                return VersionComparator.compare(asset.version, current.runtimeVersion) == .orderedDescending
            }

        let compatibleRuntime = candidates
            .filter { runtimeAssetSupportsCurrentApp($0) }
            .sorted { VersionComparator.compare($0.version, $1.version) == .orderedDescending }
            .first

        let appBlockedRuntime = candidates
            .compactMap { appUpdateRequirement(for: $0) }
            .filter { requirement in
                guard let compatibleRuntime else { return true }
                return VersionComparator.compare(requirement.runtime.version, compatibleRuntime.version) == .orderedDescending
            }
            .sorted { VersionComparator.compare($0.runtime.version, $1.runtime.version) == .orderedDescending }
            .first

        return RuntimeUpdateSelection(
            compatibleRuntime: compatibleRuntime,
            newerRuntimeRequiringAppUpdate: appBlockedRuntime
        )
    }

    private func runtimeAssetSupportsCurrentApp(_ asset: RuntimeReleaseAsset) -> Bool {
        appUpdateRequirement(for: asset) == nil
    }

    private func appUpdateRequirement(for asset: RuntimeReleaseAsset) -> RuntimeAppUpdateRequirement? {
        guard let requiredAppVersion = asset.minAppVersion else { return nil }
        guard let currentAppVersion = appVersionProvider() else {
            return RuntimeAppUpdateRequirement(
                runtime: asset,
                requiredAppVersion: requiredAppVersion,
                currentAppVersion: nil
            )
        }
        guard VersionComparator.compare(currentAppVersion, requiredAppVersion) == .orderedAscending else {
            return nil
        }
        return RuntimeAppUpdateRequirement(
            runtime: asset,
            requiredAppVersion: requiredAppVersion,
            currentAppVersion: currentAppVersion
        )
    }

    private func fetchRuntimeArchive(_ asset: RuntimeReleaseAsset) async throws -> URL {
        if asset.url.isFileURL {
            return asset.url
        }

        try FileManager.default.createDirectory(at: runtimeArchiveCacheDirectory, withIntermediateDirectories: true)

        let archiveExtension = asset.url.pathExtension.isEmpty ? "zip" : asset.url.pathExtension
        let archiveName = "runtime-\(asset.sha256.lowercased())"
        let destination = runtimeArchiveCacheDirectory
            .appendingPathComponent(archiveName)
            .appendingPathExtension(archiveExtension)
        let partial = runtimeArchiveCacheDirectory
            .appendingPathComponent(".\(archiveName)")
            .appendingPathExtension("\(archiveExtension).download")

        if let expectedBytes = asset.sizeBytes,
           fileSize(destination) == expectedBytes {
            return destination
        }

        var attempt = 0
        var lastError: Error?
        while attempt < 4 {
            attempt += 1
            let resumeOffset = resumableRuntimeArchiveSize(at: partial, expectedBytes: asset.sizeBytes)
            if resumeOffset > 0 {
                updateRuntimeDownloadProgress(
                    RuntimeDownloadProgress(downloadedBytes: resumeOffset, totalBytes: asset.sizeBytes)
                )
            }

            let downloader = StreamingFileDownload(
                request: URLRequest(url: asset.url),
                temporaryURL: partial,
                resumeOffset: resumeOffset,
                configuration: runtimeArchiveDownloadConfiguration
            ) { [weak self] bytesWritten in
                Task { @MainActor in
                    self?.updateRuntimeDownloadProgress(
                        RuntimeDownloadProgress(downloadedBytes: bytesWritten, totalBytes: asset.sizeBytes)
                    )
                }
            }

            do {
                let result = try await downloader.start()
                try validateRuntimeArchiveHTTPResponse(result.response)
                try finalizeRuntimeArchiveDownload(
                    partialURL: partial,
                    destinationURL: destination,
                    expectedBytes: asset.sizeBytes
                )
                return destination
            } catch {
                lastError = error
                guard shouldRetryRuntimeArchiveDownload(after: error), attempt < 4 else {
                    throw error
                }

                try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            }
        }

        throw lastError ?? URLError(.unknown)
    }

    private func validateRuntimeArchiveHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func finalizeRuntimeArchiveDownload(
        partialURL: URL,
        destinationURL: URL,
        expectedBytes: Int64?
    ) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: partialURL, to: destinationURL)
        if let expectedBytes {
            updateRuntimeDownloadProgress(
                RuntimeDownloadProgress(downloadedBytes: expectedBytes, totalBytes: expectedBytes)
            )
        }
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private func resumableRuntimeArchiveSize(at partialURL: URL, expectedBytes: Int64?) -> Int64 {
        guard let partialSize = fileSize(partialURL), partialSize > 0 else {
            return 0
        }

        if let expectedBytes, partialSize >= expectedBytes {
            try? FileManager.default.removeItem(at: partialURL)
            return 0
        }

        return partialSize
    }

    private func shouldRetryRuntimeArchiveDownload(after error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }
        return [
            .networkConnectionLost,
            .timedOut,
            .notConnectedToInternet,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed
        ].contains(urlError.code)
    }
}
