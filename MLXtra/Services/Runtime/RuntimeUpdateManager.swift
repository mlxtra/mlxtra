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
    private let currentComponentManifestProvider: (RuntimeComponent) -> RuntimeManifest?
    private let appVersionProvider: () -> String?
    private let channelSession: URLSession
    private let runtimeArchiveInstaller: RuntimeArchiveInstaller
    private let runtimeArchiveDownloadConfiguration: URLSessionConfiguration
    private let runtimeArchiveCacheDirectory: URL
    private var backgroundTask: Task<Void, Never>?
    private var activeRefreshID: UUID?
    private var activeInstallID: UUID?
    private var runtimeDownloadSpeedTracker = RuntimeDownloadSpeedTracker()

    init(
        currentManifestProvider: @escaping () -> RuntimeManifest? = { RuntimeManager.activeRuntimeManifest() },
        currentComponentManifestProvider: @escaping (RuntimeComponent) -> RuntimeManifest? = {
            RuntimeManager.activeRuntimeManifest(component: $0)
        },
        appVersionProvider: @escaping () -> String? = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        },
        channelSession: URLSession = .shared,
        runtimeArchiveInstaller: @escaping RuntimeArchiveInstaller = { archiveURL, progressHandler in
            try RuntimeManager.installRuntimeArchive(archiveURL, progressHandler: progressHandler)
        },
        runtimeArchiveDownloadConfiguration: URLSessionConfiguration = .default,
        runtimeArchiveCacheDirectory: URL = RuntimeManager.appSupportURL()
            .appendingPathComponent("downloads")
            .appendingPathComponent("runtime")
    ) {
        self.currentManifestProvider = currentManifestProvider
        self.currentComponentManifestProvider = currentComponentManifestProvider
        self.appVersionProvider = appVersionProvider
        self.channelSession = channelSession
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
        reportFailures: Bool = false,
        component: RuntimeComponent = .base
    ) {
        startBackgroundTask {
            await $0.bootstrapStableRuntimeIfNeeded(
                channelURL: channelURL,
                reportFailures: reportFailures,
                component: component
            )
        }
    }

    func installRuntimeInBackground(_ asset: RuntimeReleaseAsset) {
        startBackgroundTask {
            await $0.installRuntime(asset)
        }
    }

    func bootstrapStableRuntimeIfNeeded(
        channelURL: URL = ReleaseChannelManifest.defaultChannelURL,
        reportFailures: Bool = false,
        component: RuntimeComponent = .base
    ) async {
        if component != .base, currentManifest(for: .base) == nil {
            await bootstrapStableRuntimeIfNeeded(
                channelURL: channelURL,
                reportFailures: reportFailures,
                component: .base
            )
            guard currentManifest(for: .base) != nil else {
                return
            }
        }

        switch state {
        case .checking, .installing:
            return
        default:
            break
        }

        await refreshStableChannel(
            channelURL: channelURL,
            reportFailures: reportFailures,
            component: component
        )
        if case .available(let asset) = state {
            await installRuntime(asset)
        }
    }

    func refreshStableChannel(
        channelURL: URL = ReleaseChannelManifest.defaultChannelURL,
        reportFailures: Bool = true,
        component: RuntimeComponent = .base
    ) async {
        guard !isInstalling else { return }

        let refreshID = UUID()
        activeRefreshID = refreshID
        state = .checking
        newerRuntimeRequiringAppUpdate = nil
        do {
            let (data, response) = try await channelSession.data(from: channelURL)
            guard isCurrentRefresh(refreshID) else { return }
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw RuntimeUpdateError.channelUnavailable
            }

            let manifest = try JSONDecoder().decode(ReleaseChannelManifest.self, from: data)
            guard isCurrentRefresh(refreshID) else { return }
            channel = manifest

            let selection = runtimeUpdateSelection(in: manifest, component: component)
            newerRuntimeRequiringAppUpdate = selection.newerRuntimeRequiringAppUpdate

            if let asset = selection.compatibleRuntime {
                state = .available(asset)
            } else if let requirement = selection.newerRuntimeRequiringAppUpdate {
                state = .requiresAppUpdate(requirement)
            } else {
                state = .idle
            }
            finishRefresh(refreshID)
        } catch is CancellationError {
            guard isCurrentRefresh(refreshID) else { return }
            state = .idle
            finishRefresh(refreshID)
        } catch {
            guard isCurrentRefresh(refreshID) else { return }
            state = reportFailures ? .failed(error.localizedDescription) : .idle
            finishRefresh(refreshID)
        }
    }

    func installRuntime(_ asset: RuntimeReleaseAsset) async {
        if case .installing = state {
            return
        }

        let installID = UUID()
        activeInstallID = installID
        activeRefreshID = nil
        installingRuntime = asset
        installPhase = .downloading
        resetRuntimeDownloadMetrics()
        runtimeDownloadProgress = asset.url.isFileURL
            ? nil
            : RuntimeDownloadProgress(downloadedBytes: 0, totalBytes: asset.sizeBytes)
        state = asset.url.isFileURL || asset.sizeBytes == nil ? .installing(nil) : .installing(0)
        do {
            let archiveURL = try await fetchRuntimeArchive(asset, installID: installID)
            guard isCurrentInstall(installID) else { return }
            let expectedSHA256 = asset.sha256
            installPhase = .verifying
            state = .installing(nil)
            let actualChecksum = try await Task.detached(priority: .utility) {
                try SHA256Checksum.hexDigest(for: archiveURL)
            }.value
            guard isCurrentInstall(installID) else { return }
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
            let installedURL = try await installRuntimeArchiveWithStructuredProgress(
                archiveURL,
                asset: asset,
                installID: installID
            )
            guard isCurrentInstall(installID) else { return }
            guard let manifest = RuntimeManager.runtimeManifest(at: installedURL, component: asset.component) else {
                throw RuntimeUpdateError.invalidRuntime
            }
            let runtimeVersion = manifest.runtimeVersion
            clearInstallProgress()
            state = .installed(runtimeVersion)
            installingRuntime = nil
            finishInstall(installID)
        } catch is CancellationError {
            guard isCurrentInstall(installID) else { return }
            clearInstallProgress()
            state = .idle
            installingRuntime = nil
            finishInstall(installID)
        } catch {
            guard isCurrentInstall(installID) else { return }
            clearInstallProgress()
            state = .failed(error.localizedDescription)
            installingRuntime = nil
            finishInstall(installID)
        }
    }

    private var isInstalling: Bool {
        if case .installing = state {
            return true
        }
        return activeInstallID != nil
    }

    private func isCurrentRefresh(_ refreshID: UUID) -> Bool {
        activeRefreshID == refreshID
    }

    private func finishRefresh(_ refreshID: UUID) {
        if activeRefreshID == refreshID {
            activeRefreshID = nil
        }
    }

    private func isCurrentInstall(_ installID: UUID) -> Bool {
        activeInstallID == installID
    }

    private func finishInstall(_ installID: UUID) {
        if activeInstallID == installID {
            activeInstallID = nil
        }
    }

    private func clearInstallProgress() {
        installPhase = .idle
        runtimeDownloadProgress = nil
        runtimeActivationProgress = nil
        resetRuntimeDownloadMetrics()
    }

    private func updateRuntimeActivationProgress(_ progress: RuntimeActivationProgress, installID: UUID) {
        guard isCurrentInstall(installID),
              case .installing = state,
              installPhase == .activating else {
            return
        }
        runtimeActivationProgress = progress
        state = .installing(progress.fractionCompleted)
    }

    private func updateRuntimeDownloadProgress(_ progress: RuntimeDownloadProgress, installID: UUID) {
        guard isCurrentInstall(installID),
              case .installing = state,
              installPhase == .downloading else {
            return
        }

        let now = Date()
        let bytesPerSecond = runtimeDownloadSpeedTracker.bytesPerSecond(for: progress, at: now)
        let measuredProgress = RuntimeDownloadProgress(
            downloadedBytes: progress.downloadedBytes,
            totalBytes: progress.totalBytes,
            bytesPerSecond: bytesPerSecond
        )
        runtimeDownloadProgress = measuredProgress
        state = .installing(measuredProgress.fractionCompleted)
    }

    private func resetRuntimeDownloadMetrics() {
        runtimeDownloadSpeedTracker.reset()
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

    private func runtimeUpdateSelection(
        in manifest: ReleaseChannelManifest,
        component: RuntimeComponent = .base
    ) -> RuntimeUpdateSelection {
        let current = currentManifest(for: component)
        let base = currentManifest(for: .base)
        let candidates = manifest.runtimes
            .filter { $0.platform == "macos" && $0.arch == "arm64" }
            .filter { $0.component == component }
            .filter { asset in
                if component != .base {
                    guard let base else { return false }
                    guard asset.compatibilityApi == base.compatibilityApi else { return false }
                }
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

    private func currentManifest(for component: RuntimeComponent) -> RuntimeManifest? {
        switch component {
        case .base:
            return currentManifestProvider()
        case .music:
            return currentComponentManifestProvider(component)
        }
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

    private func fetchRuntimeArchive(_ asset: RuntimeReleaseAsset, installID: UUID) async throws -> URL {
        if asset.url.isFileURL {
            return asset.url
        }

        try FileManager.default.createDirectory(at: runtimeArchiveCacheDirectory, withIntermediateDirectories: true)

        let archiveExtension = asset.url.pathExtension.isEmpty ? "zip" : asset.url.pathExtension
        let archiveName = "runtime-\(asset.component.rawValue)-\(asset.sha256.lowercased())"
        let destination = runtimeArchiveCacheDirectory
            .appendingPathComponent(archiveName)
            .appendingPathExtension(archiveExtension)
        let partial = runtimeArchiveCacheDirectory
            .appendingPathComponent(".\(archiveName)")
            .appendingPathExtension("\(archiveExtension).download")

        if let expectedBytes = asset.sizeBytes,
           StreamingFileDownloader.fileSize(destination) == expectedBytes {
            return destination
        }

        let downloader = StreamingFileDownloader(
            configuration: runtimeArchiveDownloadConfiguration,
            maxAttempts: 4,
            shouldRetry: { StreamingFileDownloader.isTransientNetworkError($0) },
            shouldPreservePartial: { StreamingFileDownloader.shouldPreservePartialDownload(after: $0) },
            retryDelay: { attempt in
                try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            }
        )

        _ = try await downloadRuntimeArchive(
            downloader: downloader,
            asset: asset,
            destination: destination,
            partial: partial,
            installID: installID
        )

        return destination
    }

    private func downloadRuntimeArchive(
        downloader: StreamingFileDownloader,
        asset: RuntimeReleaseAsset,
        destination: URL,
        partial: URL,
        installID: UUID
    ) async throws -> StreamingFileDownloadResult {
        let (progressStream, progressContinuation) = AsyncStream.makeStream(
            of: Int64.self,
            bufferingPolicy: .unbounded
        )
        let progressTask = Task<Void, Never> { @MainActor [weak self] in
            for await bytesWritten in progressStream {
                self?.updateRuntimeDownloadProgress(
                    RuntimeDownloadProgress(downloadedBytes: bytesWritten, totalBytes: asset.sizeBytes),
                    installID: installID
                )
            }
        }

        do {
            let result = try await downloader.download(
                request: URLRequest(url: asset.url),
                destinationURL: destination,
                temporaryURL: partial,
                expectedBytes: asset.sizeBytes,
                validateResponse: { response in
                    try Self.validateRuntimeArchiveHTTPResponse(response)
                },
                onProgress: { bytesWritten in
                    progressContinuation.yield(bytesWritten)
                }
            )
            progressContinuation.finish()
            await progressTask.value
            return result
        } catch {
            progressContinuation.finish()
            progressTask.cancel()
            await progressTask.value
            throw error
        }
    }

    private func installRuntimeArchiveWithStructuredProgress(
        _ archiveURL: URL,
        asset: RuntimeReleaseAsset,
        installID: UUID
    ) async throws -> URL {
        let installer = runtimeArchiveInstaller
        let (progressStream, progressContinuation) = AsyncStream.makeStream(
            of: RuntimeActivationProgress.self,
            bufferingPolicy: .unbounded
        )
        let progressTask = Task<Void, Never> { @MainActor [weak self] in
            for await progress in progressStream {
                self?.updateRuntimeActivationProgress(progress, installID: installID)
            }
        }
        let installerTask = Task.detached(priority: .utility) {
            defer { progressContinuation.finish() }
            switch asset.component {
            case .base:
                return try installer(archiveURL) { progress in
                    progressContinuation.yield(progress)
                }
            case .music:
                return try RuntimeManager.installRuntimeComponentArchive(
                    archiveURL,
                    component: asset.component
                ) { progress in
                    progressContinuation.yield(progress)
                }
            }
        }

        do {
            let installedURL = try await installerTask.value
            await progressTask.value
            return installedURL
        } catch {
            installerTask.cancel()
            progressContinuation.finish()
            progressTask.cancel()
            await progressTask.value
            throw error
        }
    }

    private nonisolated static func validateRuntimeArchiveHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
