import Foundation
import Combine
import CryptoKit

private enum RuntimeDiagnostics {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MLXTRA_RUNTIME_DEBUG"] == "1"
            || UserDefaults.standard.bool(forKey: "MLXtra.runtimeDebug")
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print(message())
    }
}

private final class PipeDataReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start(on queue: DispatchQueue, group: DispatchGroup) {
        group.enter()
        queue.async {
            let readData = self.handle.readDataToEndOfFile()
            self.lock.lock()
            self.data = readData
            self.lock.unlock()
            group.leave()
        }
    }

    func collectedData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private struct DownloadSupportValidationContext: Sendable {
    let runtimeBundleURL: URL
    let pythonHomePath: URL
    let pythonExecutablePath: URL
    let helperPath: URL
    let importPackages: [String]
    let importContext: String
    let environment: [String: String]
}

struct RuntimeImageRuntimes: Codable, Equatable {
    let mflux: RuntimeMFluxCapabilities?

    init(mflux: RuntimeMFluxCapabilities? = nil) {
        self.mflux = mflux
    }
}

struct RuntimeMFluxCapabilities: Codable, Equatable {
    let configs: [String]
    let classes: [String]
    let quantizeBits: [Int]

    init(configs: [String] = [], classes: [String] = [], quantizeBits: [Int] = []) {
        self.configs = configs
        self.classes = classes
        self.quantizeBits = quantizeBits
    }

    func supports(_ options: MFluxRuntimeOptions) -> Bool {
        if !configs.isEmpty && !configs.contains(options.config) {
            return false
        }
        if !classes.isEmpty {
            guard classes.contains(options.textToImageClass),
                  classes.contains(options.editClass) else {
                return false
            }
        }
        if let quantize = options.quantize,
           !quantizeBits.isEmpty,
           !quantizeBits.contains(quantize) {
            return false
        }
        return true
    }
}

struct RuntimeAudioRuntimes: Codable, Equatable {
    let adapters: [String]

    init(adapters: [String] = []) {
        self.adapters = adapters
    }

    func supports(_ options: AudioRuntimeOptions) -> Bool {
        adapters.isEmpty || adapters.contains(options.adapter)
    }
}

struct RuntimeManifest: Codable, Equatable {
    let runtimeVersion: String
    let compatibilityApi: Int
    let platform: String
    let arch: String
    let channel: String?
    let pythonVersion: String?
    let pythonPath: String?
    let executables: [String: String]?
    let packages: [String]
    let isolatedPackages: [String]
    let supportedModels: [String]?
    let supportedBackends: [RuntimeBackend]
    let capabilities: [String]
    let imageRuntimes: RuntimeImageRuntimes?
    let audioRuntimes: RuntimeAudioRuntimes?

    init(
        runtimeVersion: String,
        compatibilityApi: Int,
        platform: String = "macos",
        arch: String = "arm64",
        channel: String? = "stable",
        pythonVersion: String? = nil,
        pythonPath: String? = nil,
        executables: [String: String]? = nil,
        packages: [String] = [],
        isolatedPackages: [String] = [],
        supportedModels: [String]? = nil,
        supportedBackends: [RuntimeBackend] = [],
        capabilities: [String] = [],
        imageRuntimes: RuntimeImageRuntimes? = nil,
        audioRuntimes: RuntimeAudioRuntimes? = nil
    ) {
        self.runtimeVersion = runtimeVersion
        self.compatibilityApi = compatibilityApi
        self.platform = platform
        self.arch = arch
        self.channel = channel
        self.pythonVersion = pythonVersion
        self.pythonPath = pythonPath
        self.executables = executables
        self.packages = packages
        self.isolatedPackages = isolatedPackages
        self.supportedModels = supportedModels
        self.supportedBackends = supportedBackends
        self.capabilities = capabilities
        self.imageRuntimes = imageRuntimes
        self.audioRuntimes = audioRuntimes
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeVersion
        case compatibilityApi
        case platform
        case arch
        case channel
        case pythonVersion
        case pythonPath
        case executables
        case packages
        case isolatedPackages
        case supportedModels
        case supportedBackends
        case capabilities
        case imageRuntimes
        case audioRuntimes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runtimeVersion = try container.decode(String.self, forKey: .runtimeVersion)
        compatibilityApi = try container.decode(Int.self, forKey: .compatibilityApi)
        platform = try container.decodeIfPresent(String.self, forKey: .platform) ?? "macos"
        arch = try container.decodeIfPresent(String.self, forKey: .arch) ?? "arm64"
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        pythonVersion = try container.decodeIfPresent(String.self, forKey: .pythonVersion)
        pythonPath = try container.decodeIfPresent(String.self, forKey: .pythonPath)
        executables = try container.decodeIfPresent([String: String].self, forKey: .executables)
        packages = try container.decodeIfPresent([String].self, forKey: .packages) ?? []
        isolatedPackages = try container.decodeIfPresent([String].self, forKey: .isolatedPackages) ?? []
        supportedModels = try container.decodeIfPresent([String].self, forKey: .supportedModels)
        supportedBackends = try container.decodeIfPresent([RuntimeBackend].self, forKey: .supportedBackends) ?? []
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        imageRuntimes = try container.decodeIfPresent(RuntimeImageRuntimes.self, forKey: .imageRuntimes)
        audioRuntimes = try container.decodeIfPresent(RuntimeAudioRuntimes.self, forKey: .audioRuntimes)
    }

    func supports(backend: RuntimeBackend) -> Bool {
        if supportedBackends.isEmpty {
            return true
        }
        return supportedBackends.contains(backend)
    }

    func supports(profile: ModelCapabilityProfile) -> Bool {
        profile.runtime.isSatisfied(by: self)
            && supports(backend: profile.backend)
            && supports(runtimeOptions: profile.runtimeOptions)
            && (supportedModels?.contains(profile.modelId) ?? true)
    }

    func supports(runtimeOptions: ModelRuntimeOptions?) -> Bool {
        guard let runtimeOptions else {
            return true
        }
        if let mflux = runtimeOptions.mflux {
            guard let capabilities = imageRuntimes?.mflux else {
                return true
            }
            guard capabilities.supports(mflux) else {
                return false
            }
        }
        if let audio = runtimeOptions.audio,
           let capabilities = audioRuntimes,
           !capabilities.supports(audio) {
            return false
        }
        return true
    }
}

enum SHA256Checksum {
    static func hexDigest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hexDigest(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct RuntimeDownloadProgress: Equatable {
    let downloadedBytes: Int64
    let totalBytes: Int64?
    let bytesPerSecond: Double?
    let estimatedSecondsRemaining: TimeInterval?

    init(downloadedBytes: Int64, totalBytes: Int64?, bytesPerSecond: Double? = nil) {
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond

        if let totalBytes,
           let bytesPerSecond,
           bytesPerSecond > 0,
           totalBytes > downloadedBytes {
            estimatedSecondsRemaining = Double(totalBytes - downloadedBytes) / bytesPerSecond
        } else {
            estimatedSecondsRemaining = nil
        }
    }

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else {
            return nil
        }
        return min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
    }
}

struct RuntimeActivationProgress: Equatable {
    let title: String
    let detail: String?
    let completedStep: Int
    let totalSteps: Int

    var fractionCompleted: Double {
        guard totalSteps > 0 else { return 0 }
        return min(max(Double(completedStep) / Double(totalSteps), 0), 1)
    }

    var stepText: String {
        "Step \(completedStep) of \(totalSteps)"
    }
}

typealias RuntimeArchiveInstaller = @Sendable (
    _ archiveURL: URL,
    _ progressHandler: @escaping @Sendable (RuntimeActivationProgress) -> Void
) throws -> URL

private struct RuntimeArchiveDownloadResult {
    let response: URLResponse
    let downloadedBytes: Int64
}

private final class RuntimeArchiveDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let sourceURL: URL
    private let destinationURL: URL
    private let partialURL: URL
    private let resumeOffset: Int64
    private let expectedBytes: Int64?
    private let configuration: URLSessionConfiguration
    private let progressHandler: @Sendable (RuntimeDownloadProgress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RuntimeArchiveDownloadResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var response: URLResponse?
    private var downloadedBytes: Int64 = 0
    private var didComplete = false

    init(
        sourceURL: URL,
        destinationURL: URL,
        partialURL: URL,
        resumeOffset: Int64,
        expectedBytes: Int64?,
        configuration: URLSessionConfiguration,
        progressHandler: @escaping @Sendable (RuntimeDownloadProgress) -> Void
    ) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.partialURL = partialURL
        self.resumeOffset = max(0, resumeOffset)
        self.expectedBytes = expectedBytes
        self.configuration = configuration
        self.progressHandler = progressHandler
    }

    func start() async throws -> URL {
        try preparePartialFile()

        return try await withTaskCancellationHandler {
            let result = try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request())
                self.session = session
                self.task = task
                lock.unlock()

                task.resume()
            }
            try validateHTTPResponse(result.response)
            try finalizePartialDownload()
            return destinationURL
        } onCancel: {
            self.cancel()
        }
    }

    private func preparePartialFile() throws {
        try FileManager.default.createDirectory(
            at: partialURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if resumeOffset == 0 || !FileManager.default.fileExists(atPath: partialURL.path) {
            try Data().write(to: partialURL, options: [.atomic])
        }
        fileHandle = try FileHandle(forWritingTo: partialURL)
        try fileHandle?.seekToEnd()
        downloadedBytes = resumeOffset
        if resumeOffset > 0 {
            progressHandler(RuntimeDownloadProgress(downloadedBytes: resumeOffset, totalBytes: expectedBytes))
        }
    }

    private func request() -> URLRequest {
        var request = URLRequest(url: sourceURL)
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        self.response = response
        let shouldRestartFromZero = resumeOffset > 0
            && (response as? HTTPURLResponse)?.statusCode == 200
        if shouldRestartFromZero {
            downloadedBytes = 0
        }
        let fileHandle = self.fileHandle
        lock.unlock()

        if shouldRestartFromZero {
            try? fileHandle?.truncate(atOffset: 0)
            try? fileHandle?.seek(toOffset: 0)
            progressHandler(RuntimeDownloadProgress(downloadedBytes: 0, totalBytes: expectedBytes))
        }

        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        do {
            try fileHandle?.write(contentsOf: data)
            lock.lock()
            downloadedBytes += Int64(data.count)
            let bytes = downloadedBytes
            lock.unlock()
            progressHandler(RuntimeDownloadProgress(downloadedBytes: bytes, totalBytes: expectedBytes))
        } catch {
            complete(.failure(error))
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            complete(.failure(error))
            return
        }

        lock.lock()
        let response = self.response
        let downloadedBytes = self.downloadedBytes
        lock.unlock()

        guard let response else {
            complete(.failure(URLError(.badServerResponse)))
            return
        }

        complete(.success(RuntimeArchiveDownloadResult(response: response, downloadedBytes: downloadedBytes)))
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func finalizePartialDownload() throws {
        try fileHandle?.close()
        fileHandle = nil

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: partialURL, to: destinationURL)
        if let expectedBytes {
            progressHandler(RuntimeDownloadProgress(downloadedBytes: expectedBytes, totalBytes: expectedBytes))
        }
    }

    private func complete(_ result: Result<RuntimeArchiveDownloadResult, Error>) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        let continuation = continuation
        self.continuation = nil
        task = nil
        let session = session
        self.session = nil
        let fileHandle = fileHandle
        self.fileHandle = nil
        lock.unlock()

        try? fileHandle?.close()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}

enum RuntimeInstallPhase: Equatable {
    case idle
    case downloading
    case verifying
    case activating
}

struct RuntimeAppUpdateRequirement: Equatable {
    let runtime: RuntimeReleaseAsset
    let requiredAppVersion: String
    let currentAppVersion: String?
}

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
        } catch is CancellationError {
            installPhase = .idle
            runtimeDownloadProgress = nil
            runtimeActivationProgress = nil
            resetRuntimeDownloadMetrics()
            state = .idle
        } catch {
            installPhase = .idle
            runtimeDownloadProgress = nil
            runtimeActivationProgress = nil
            resetRuntimeDownloadMetrics()
            state = .failed(error.localizedDescription)
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
            let downloader = RuntimeArchiveDownloader(
                sourceURL: asset.url,
                destinationURL: destination,
                partialURL: partial,
                resumeOffset: resumeOffset,
                expectedBytes: asset.sizeBytes,
                configuration: runtimeArchiveDownloadConfiguration
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.updateRuntimeDownloadProgress(progress)
                }
            }

            do {
                return try await downloader.start()
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
            .cancelled,
            .networkConnectionLost,
            .timedOut,
            .notConnectedToInternet,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed
        ].contains(urlError.code)
    }
}

enum RuntimeUpdateError: LocalizedError {
    case channelUnavailable
    case checksumMismatch
    case invalidRuntime
    case unsupportedArchive

    var errorDescription: String? {
        switch self {
        case .channelUnavailable:
            return "No runtime update channel is available yet"
        case .checksumMismatch:
            return "Runtime archive checksum did not match"
        case .invalidRuntime:
            return "Downloaded runtime did not pass validation"
        case .unsupportedArchive:
            return "Runtime archive format is not supported"
        }
    }
}

@MainActor
class RuntimeManager: ObservableObject {
    @Published var state: RuntimeState = .notInitialized
    @Published var loadingMessage: String = ""
    @Published var isModelLoaded: Bool = false
    
    enum RuntimeState: Equatable {
        case notInitialized
        case checkingBundle
        case extractingBundle
        case startingPython
        case ready
        case error(String)
    }

    enum ModelStorageStatus: Equatable {
        case missing
        case incomplete(String)
        case downloaded

        var isDownloaded: Bool {
            self == .downloaded
        }
    }
    
    private var runtimeBundleURL: URL {
        Self.activeRuntimeBundleURL()
    }
    
    private var appSupportURL: URL {
        Self.appSupportURL()
    }

    var checkpointsPath: URL {
        appSupportURL.appendingPathComponent("checkpoints")
    }

    nonisolated static func appSupportURL(fileManager: FileManager = .default) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return baseURL.appendingPathComponent("MLXtra")
    }

    nonisolated static func installedRuntimeURL(fileManager: FileManager = .default) -> URL {
        appSupportURL(fileManager: fileManager)
            .appendingPathComponent("runtimes")
            .appendingPathComponent("macos-arm64")
            .appendingPathComponent("current")
    }

    nonisolated static func bundledRuntimeCandidates(bundle: Bundle = .main) -> [URL] {
        [
            bundle.bundleURL.appendingPathComponent("Contents/Resources/runtime/macos-arm64"),
            bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("Resources/runtime/macos-arm64"),
            bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/runtime/macos-arm64"),
        ]
    }

    nonisolated static func activeRuntimeBundleURL(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL {
        let installed = installedRuntimeURL(fileManager: fileManager)
        return preferredRuntimeBundleURL(
            installed: installed,
            bundledCandidates: bundledRuntimeCandidates(bundle: bundle),
            fileManager: fileManager
        )
    }

    nonisolated static func preferredRuntimeBundleURL(
        installed: URL,
        bundledCandidates candidates: [URL],
        fileManager: FileManager = .default
    ) -> URL {
        if isRuntimeBundleStructurallyValid(installed, fileManager: fileManager) {
            RuntimeDiagnostics.log("[RuntimeManager] Using installed runtime bundle at: \(installed.path)")
            return installed
        }

        for path in candidates where isRuntimeBundleStructurallyValid(path, fileManager: fileManager) {
            RuntimeDiagnostics.log("[RuntimeManager] Found bundled runtime bundle at: \(path.path)")
            return path
        }

        RuntimeDiagnostics.log("[RuntimeManager] Runtime bundle not found in expected locations, using default")
        return candidates[0]
    }

    nonisolated static func activeRuntimeManifest() -> RuntimeManifest? {
        let runtimeURL = activeRuntimeBundleURL()
        guard isRuntimeBundleStructurallyValid(runtimeURL) else {
            return nil
        }
        return runtimeManifest(at: runtimeURL)
    }

    nonisolated static func runtimeManifest(at runtimeURL: URL) -> RuntimeManifest? {
        let manifestURL = runtimeURL.appendingPathComponent("runtime-manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(RuntimeManifest.self, from: data)
    }

    nonisolated static func isRuntimeBundleStructurallyValid(
        _ runtimeURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: runtimeURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              runtimeManifest(at: runtimeURL) != nil else {
            return false
        }

        let requiredFiles = [
            "venv/bin/python",
            "acestep-venv/bin/python",
            "python/Frameworks/Versions/3.12",
            "acestep_download_helper.py",
            "runtime-manifest.json",
        ]
        guard requiredFiles.allSatisfy({ relativePath in
            fileManager.fileExists(atPath: runtimeURL.appendingPathComponent(relativePath).path)
        }) else {
            return false
        }

        let requiredExecutables = [
            "venv/bin/python",
            "acestep-venv/bin/python",
        ]
        return requiredExecutables.allSatisfy { relativePath in
            fileManager.isExecutableFile(atPath: runtimeURL.appendingPathComponent(relativePath).path)
        }
    }

    nonisolated static func installRuntimeArchive(
        _ archiveURL: URL,
        fileManager: FileManager = .default,
        progressHandler: @escaping @Sendable (RuntimeActivationProgress) -> Void = { _ in }
    ) throws -> URL {
        let installRoot = installedRuntimeURL(fileManager: fileManager).deletingLastPathComponent()
        return try installRuntimeArchive(
            archiveURL,
            installRoot: installRoot,
            fileManager: fileManager,
            progressHandler: progressHandler
        )
    }

    nonisolated static func installRuntimeArchive(
        _ archiveURL: URL,
        installRoot: URL,
        fileManager: FileManager = .default,
        progressHandler: @escaping @Sendable (RuntimeActivationProgress) -> Void = { _ in }
    ) throws -> URL {
        progressHandler(RuntimeActivationProgress(
            title: "Preparing local files",
            detail: "Creating a temporary install area.",
            completedStep: 1,
            totalSteps: 5
        ))
        let stagingURL = installRoot.appendingPathComponent("staging-\(UUID().uuidString)")
        let extractedURL = stagingURL.appendingPathComponent("extract")
        try fileManager.createDirectory(at: extractedURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingURL) }

        if archiveURL.hasDirectoryPath {
            progressHandler(RuntimeActivationProgress(
                title: "Copying local files",
                detail: "Preparing the runtime directory.",
                completedStep: 2,
                totalSteps: 5
            ))
            try fileManager.copyItem(at: archiveURL, to: extractedURL.appendingPathComponent(archiveURL.lastPathComponent))
        } else if archiveURL.pathExtension.lowercased() == "zip" {
            let archiveSize = formattedFileSize(archiveURL, fileManager: fileManager)
            progressHandler(RuntimeActivationProgress(
                title: "Extracting archive",
                detail: archiveSize.map { "Unpacking \($0) of runtime files." } ?? "Unpacking runtime files.",
                completedStep: 2,
                totalSteps: 5
            ))
            try extractZipArchive(archiveURL, to: extractedURL)
        } else {
            throw RuntimeUpdateError.unsupportedArchive
        }

        progressHandler(RuntimeActivationProgress(
            title: "Validating files",
            detail: "Checking Python runtimes and required components.",
            completedStep: 3,
            totalSteps: 5
        ))
        let runtimeRoot = try normalizedRuntimeRoot(in: extractedURL, fileManager: fileManager)
        try validateExtractedRuntimeTree(runtimeRoot, fileManager: fileManager)
        guard isRuntimeBundleStructurallyValid(runtimeRoot, fileManager: fileManager) else {
            throw RuntimeUpdateError.invalidRuntime
        }

        progressHandler(RuntimeActivationProgress(
            title: "Moving into place",
            detail: "Replacing the active runtime atomically.",
            completedStep: 4,
            totalSteps: 5
        ))
        let currentURL = installRoot.appendingPathComponent("current")
        let nextURL = installRoot.appendingPathComponent("next-\(UUID().uuidString)")
        try fileManager.createDirectory(at: installRoot, withIntermediateDirectories: true)
        try fileManager.moveItem(at: runtimeRoot, to: nextURL)

        let previousURL = installRoot.appendingPathComponent("previous-\(UUID().uuidString)")
        if fileManager.fileExists(atPath: currentURL.path) {
            try fileManager.moveItem(at: currentURL, to: previousURL)
        }
        do {
            try fileManager.moveItem(at: nextURL, to: currentURL)
            try? fileManager.removeItem(at: previousURL)
        } catch {
            if fileManager.fileExists(atPath: previousURL.path) {
                try? fileManager.moveItem(at: previousURL, to: currentURL)
            }
            throw error
        }
        progressHandler(RuntimeActivationProgress(
            title: "Finishing setup",
            detail: "Runtime is ready for local models.",
            completedStep: 5,
            totalSteps: 5
        ))
        return currentURL
    }

    private nonisolated static func formattedFileSize(_ url: URL, fileManager: FileManager) -> String? {
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size.int64Value)
    }

    private nonisolated static func extractZipArchive(_ archiveURL: URL, to destinationURL: URL) throws {
        try validateZipArchiveEntries(archiveURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RuntimeUpdateError.unsupportedArchive
        }
    }

    private nonisolated static func normalizedRuntimeRoot(
        in extractedURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        if isRuntimeBundleStructurallyValid(extractedURL, fileManager: fileManager) {
            return extractedURL
        }

        let children = try fileManager.contentsOfDirectory(
            at: extractedURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children where isRuntimeBundleStructurallyValid(child, fileManager: fileManager) {
            return child
        }
        throw RuntimeUpdateError.invalidRuntime
    }

    private nonisolated static func validateZipArchiveEntries(_ archiveURL: URL) throws {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", archiveURL.path]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw RuntimeUpdateError.unsupportedArchive
        }

        let stdoutReader = PipeDataReader(handle: outputPipe.fileHandleForReading)
        let stderrReader = PipeDataReader(handle: errorPipe.fileHandleForReading)
        let group = DispatchGroup()
        stdoutReader.start(on: DispatchQueue(label: "com.localstudio.mlxtra.zipinfo.stdout", qos: .utility), group: group)
        stderrReader.start(on: DispatchQueue(label: "com.localstudio.mlxtra.zipinfo.stderr", qos: .utility), group: group)
        process.waitUntilExit()
        group.wait()

        guard process.terminationStatus == 0 else {
            throw RuntimeUpdateError.unsupportedArchive
        }

        let output = String(data: stdoutReader.collectedData(), encoding: .utf8) ?? ""
        for rawEntry in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard isSafeArchiveEntryPath(String(rawEntry)) else {
                throw RuntimeUpdateError.invalidRuntime
            }
        }
    }

    private nonisolated static func isSafeArchiveEntryPath(_ entry: String) -> Bool {
        guard !entry.isEmpty, !entry.hasPrefix("/") else {
            return false
        }
        let components = entry.split(separator: "/", omittingEmptySubsequences: true)
        return !components.contains("..")
    }

    private nonisolated static func validateExtractedRuntimeTree(
        _ rootURL: URL,
        fileManager: FileManager
    ) throws {
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            throw RuntimeUpdateError.invalidRuntime
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink == true else {
                continue
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard isURL(resolved, containedIn: root) else {
                throw RuntimeUpdateError.invalidRuntime
            }
        }
    }

    private nonisolated static func isURL(_ candidate: URL, containedIn root: URL) -> Bool {
        let candidatePath = candidate.path
        let rootPath = root.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
    
    func initialize() async throws {
        switch state {
        case .notInitialized, .error:
            break
        default:
            return
        }

        state = .checkingBundle
        loadingMessage = "Checking Python runtime..."

        do {
            let bundlePath = runtimeBundleURL
            try Self.validateRequiredDirectory(bundlePath, error: .bundleNotFound(bundlePath.path))

            let pythonHome = pythonHomePath()
            try Self.validateRequiredDirectory(
                pythonHome,
                error: .runtimeComponentNotFound("Bundled Python home", pythonHome.path)
            )

            let pythonPath = pythonExecutablePath()
            try Self.validateRequiredFile(pythonPath, error: .pythonNotFound(pythonPath.path), executable: true)

            let bridgePath = bridgeScriptPath()
            try Self.validateRequiredFile(bridgePath, error: .bridgeScriptNotFound(bridgePath.path))

            let aceStepPython = acestepPythonExecutablePath()
            try Self.validateRequiredFile(
                aceStepPython,
                error: .runtimeComponentNotFound("ACE-Step Python executable", aceStepPython.path),
                executable: true
            )

            let aceStepHelper = acestepDownloadHelperPath()
            try Self.validateRequiredFile(
                aceStepHelper,
                error: .runtimeComponentNotFound("ACE-Step download helper", aceStepHelper.path)
            )
        } catch let runtimeError as RuntimeError {
            state = .error(runtimeError.localizedDescription)
            throw runtimeError
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }

        state = .ready
        loadingMessage = ""
    }

    func validateDownloadSupport(for modelId: String) throws {
        try validateDownloadSupport(
            for: Self.embeddedModelForRuntimeLookup(modelId: modelId) ?? DownloadableModel(
                id: modelId,
                name: modelId,
                subtitle: "",
                modelId: modelId,
                modality: .vision,
                downloadSizeGB: 0
            )
        )
    }

    /// Downloading should not require unrelated model runtimes to be present.
    func validateDownloadSupport(for model: DownloadableModel) throws {
        guard model.source.usesComponentBundle else {
            return
        }
        let context = try downloadSupportValidationContext(for: model)
        try Self.validateDownloadSupport(context)
    }

    func validateDownloadSupportOffMain(for model: DownloadableModel) async throws {
        guard model.source.usesComponentBundle else {
            return
        }
        let context = try downloadSupportValidationContext(for: model)
        try await Task.detached(priority: .utility) {
            try Self.validateDownloadSupport(context)
        }.value
    }

    private func downloadSupportValidationContext(for model: DownloadableModel) throws -> DownloadSupportValidationContext {
        guard model.source.helper == .aceStep else {
            throw NativeModelDownloadError.unsupportedComponentBundle(model.name)
        }

        let aceStepPython = acestepPythonExecutablePath()
        let aceStepHelper = acestepDownloadHelperPath()
        return DownloadSupportValidationContext(
            runtimeBundleURL: runtimeBundleURL,
            pythonHomePath: pythonHomePath(),
            pythonExecutablePath: aceStepPython,
            helperPath: aceStepHelper,
            importPackages: ["huggingface_hub", "tqdm", "acestep"],
            importContext: "ACE-Step download runtime",
            environment: bundledPythonEnvironment()
        )
    }

    private nonisolated static func validateDownloadSupport(_ context: DownloadSupportValidationContext) throws {
        try validateRequiredDirectory(
            context.runtimeBundleURL,
            error: .bundleNotFound(context.runtimeBundleURL.path)
        )
        try validateRequiredDirectory(
            context.pythonHomePath,
            error: .runtimeComponentNotFound("Bundled Python home", context.pythonHomePath.path)
        )

        try validateRequiredFile(
            context.pythonExecutablePath,
            error: .runtimeComponentNotFound("ACE-Step Python executable", context.pythonExecutablePath.path),
            executable: true
        )
        try validateRequiredFile(
            context.helperPath,
            error: .runtimeComponentNotFound("ACE-Step download helper", context.helperPath.path)
        )

        try validatePythonImports(
            pythonPath: context.pythonExecutablePath,
            packages: context.importPackages,
            context: context.importContext,
            environment: context.environment
        )
    }

    private nonisolated static func validatePythonImports(
        pythonPath: URL,
        packages: [String],
        context: String,
        environment: [String: String]
    ) throws {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = pythonPath
        process.arguments = [
            "-c",
            "import importlib, sys; [importlib.import_module(package) for package in sys.argv[1:]]",
        ] + packages
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw RuntimeError.pythonValidationFailed(context, error.localizedDescription)
        }

        let group = DispatchGroup()
        let stdoutReader = PipeDataReader(handle: outputPipe.fileHandleForReading)
        let stderrReader = PipeDataReader(handle: errorPipe.fileHandleForReading)
        let stdoutQueue = DispatchQueue(label: "com.localstudio.mlxtra.runtime-validation.stdout", qos: .utility)
        let stderrQueue = DispatchQueue(label: "com.localstudio.mlxtra.runtime-validation.stderr", qos: .utility)

        stdoutReader.start(on: stdoutQueue, group: group)
        stderrReader.start(on: stderrQueue, group: group)
        process.waitUntilExit()
        group.wait()

        guard process.terminationStatus == 0 else {
            let stdoutData = stdoutReader.collectedData()
            let stderrData = stderrReader.collectedData()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let details = (stderr.isEmpty ? stdout : stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RuntimeError.pythonValidationFailed(context, details.isEmpty ? "Python exited with status \(process.terminationStatus)" : details)
        }
    }

    private func bundledPythonEnvironment() -> [String: String] {
        Self.bundledPythonEnvironment(pythonHome: pythonHomePath())
    }

    private nonisolated static func bundledPythonEnvironment(pythonHome: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["PYTHONPATH", "VIRTUAL_ENV", "CONDA_PREFIX", "CONDA_DEFAULT_ENV", "PYENV_ROOT", "PYENV_VERSION"] {
            environment.removeValue(forKey: key)
        }
        environment["PYTHONHOME"] = pythonHome.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return environment
    }

    private nonisolated static func validateRequiredDirectory(_ url: URL, error: RuntimeError) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw error
        }
    }

    private nonisolated static func validateRequiredFile(_ url: URL, error: RuntimeError, executable: Bool = false) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw error
        }

        if executable && !FileManager.default.isExecutableFile(atPath: url.path) {
            throw error
        }
    }
    
    func pythonExecutablePath() -> URL {
        runtimeBundleURL.appendingPathComponent("venv/bin/python")
    }

    func acestepPythonExecutablePath() -> URL {
        runtimeBundleURL.appendingPathComponent("acestep-venv/bin/python")
    }

    func acestepDownloadHelperPath() -> URL {
        runtimeBundleURL.appendingPathComponent("acestep_download_helper.py")
    }
    
    func pythonSitePackagesPath() -> URL {
        for version in ["python3.13", "python3.12", "python3.11"] {
            let path = runtimeBundleURL.appendingPathComponent("venv/lib/\(version)/site-packages")
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }
        return runtimeBundleURL.appendingPathComponent("venv/lib/python3.12/site-packages")
    }
    
    /// This must be set as PYTHONHOME when launching the bundled Python so
    /// it can locate the standard library and C extension modules.
    func pythonHomePath() -> URL {
        runtimeBundleURL
            .appendingPathComponent("python/Frameworks/Versions/3.12")
    }

    func bridgeScriptPath() -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/python_bridge.py")
    }
    
    func modelCachePath(modelId: String) -> URL {
        Self.modelCachePath(modelId: modelId)
    }

    nonisolated static func huggingFaceCacheRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
    }

    nonisolated static func modelCachePath(
        modelId: String,
        huggingFaceCacheRoot: URL = RuntimeManager.huggingFaceCacheRoot()
    ) -> URL {
        huggingFaceCacheRoot
            .appendingPathComponent("models--" + modelId.replacingOccurrences(of: "/", with: "--"))
    }

    private nonisolated static func embeddedModelForRuntimeLookup(modelId: String) -> DownloadableModel? {
        if let model = DownloadableModel.embeddedModel(modelId: modelId) {
            return model
        }

        guard let aceStepLocalId = aceStepLocalModelId(modelId) else {
            return nil
        }

        return ModelCapabilityProfile.embedded.first { profile in
            guard profile.source.helper == .aceStep else { return false }
            return profile.source.components.contains { component in
                guard component.hasPrefix("acestep-v15-") else { return false }
                return aceStepLocalId == component || aceStepLocalId.hasPrefix(component + "-")
            }
        }?.downloadableModel
    }

    private nonisolated static func aceStepLocalModelId(_ modelId: String) -> String? {
        let namespace = "ACE-Step/"
        if modelId.hasPrefix(namespace) {
            return String(modelId.dropFirst(namespace.count))
        }
        if modelId.hasPrefix("acestep-") {
            return modelId
        }
        return nil
    }

    /// Hugging Face models use the default HF cache so downloads can be shared with other apps.
    func modelStoragePath(modelId: String) -> URL {
        if let model = Self.embeddedModelForRuntimeLookup(modelId: modelId) {
            return modelStoragePath(for: model)
        }
        return modelCachePath(modelId: modelId)
    }

    func modelStoragePath(for model: DownloadableModel) -> URL {
        if model.source.usesComponentBundle {
            return checkpointsPath
        }
        return modelCachePath(modelId: model.source.downloadRepository ?? model.modelId)
    }

    func isModelDownloaded(modelId: String) -> Bool {
        Self.isModelDownloaded(modelId: modelId, checkpointsPath: checkpointsPath)
    }

    nonisolated static func isModelDownloaded(
        modelId: String,
        checkpointsPath: URL,
        huggingFaceCacheRoot: URL = RuntimeManager.huggingFaceCacheRoot()
    ) -> Bool {
        modelStorageStatus(
            modelId: modelId,
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: huggingFaceCacheRoot
        ).isDownloaded
    }

    func modelStorageStatus(modelId: String) -> ModelStorageStatus {
        Self.modelStorageStatus(modelId: modelId, checkpointsPath: checkpointsPath)
    }

    nonisolated static func modelStorageStatus(
        modelId: String,
        checkpointsPath: URL,
        huggingFaceCacheRoot: URL = RuntimeManager.huggingFaceCacheRoot()
    ) -> ModelStorageStatus {
        if let model = embeddedModelForRuntimeLookup(modelId: modelId) {
            return modelStorageStatus(
                model: model,
                checkpointsPath: checkpointsPath,
                huggingFaceCacheRoot: huggingFaceCacheRoot
            )
        }

        return huggingFaceModelStorageStatus(
            modelId: modelId,
            huggingFaceCacheRoot: huggingFaceCacheRoot
        )
    }

    private nonisolated static func huggingFaceModelStorageStatus(
        modelId: String,
        huggingFaceCacheRoot: URL
    ) -> ModelStorageStatus {
        let path = modelCachePath(modelId: modelId, huggingFaceCacheRoot: huggingFaceCacheRoot)
        RuntimeDiagnostics.log("[RuntimeManager] Checking HF cache for \(modelId) at \(path.path)")

        guard FileManager.default.fileExists(atPath: path.path),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: path.path),
              !contents.isEmpty else {
            RuntimeDiagnostics.log("[RuntimeManager] Model \(modelId) not in HF cache")
            return .missing
        }

        let snapshotsPath = path.appendingPathComponent("snapshots")
        var markerIncompleteMessage: String?
        if FileManager.default.fileExists(atPath: snapshotsPath.path) {
            for snapshotPath in Self.snapshotCandidates(modelCachePath: path, snapshotsPath: snapshotsPath) {
                if let nativeStatus = Self.nativeSnapshotStorageStatus(snapshotPath) {
                    switch nativeStatus {
                    case .downloaded:
                        RuntimeDiagnostics.log("[RuntimeManager] Model \(modelId) found in native HF cache at \(snapshotPath.path)")
                        return .downloaded
                    case .incomplete(let message):
                        markerIncompleteMessage = markerIncompleteMessage ?? message
                        continue
                    case .missing:
                        continue
                    }
                }
                if Self.snapshotContainsModelFiles(snapshotPath) {
                    RuntimeDiagnostics.log("[RuntimeManager] Model \(modelId) found in HF cache at \(snapshotPath.path)")
                    return .downloaded
                }
            }
        }

        if let markerIncompleteMessage {
            RuntimeDiagnostics.log("[RuntimeManager] Model \(modelId) native HF cache is incomplete")
            return .incomplete(markerIncompleteMessage)
        }

        RuntimeDiagnostics.log("[RuntimeManager] Model \(modelId) cache is incomplete")
        return .incomplete("Local Hugging Face cache is incomplete. Repair will verify the snapshot and redownload missing files.")
    }

    nonisolated static func modelStorageStatus(
        model: DownloadableModel,
        checkpointsPath: URL,
        huggingFaceCacheRoot: URL = RuntimeManager.huggingFaceCacheRoot()
    ) -> ModelStorageStatus {
        if model.source.usesComponentBundle {
            if model.source.helper == .aceStep {
                return aceStepModelStorageStatus(
                    checkpointsPath: checkpointsPath,
                    repoID: model.source.downloadRepository ?? model.modelId,
                    components: model.source.components
                )
            }
            return componentBundleStorageStatus(
                checkpointsPath: checkpointsPath,
                components: model.source.components
            )
        }

        return huggingFaceModelStorageStatus(
            modelId: model.source.downloadRepository ?? model.modelId,
            huggingFaceCacheRoot: huggingFaceCacheRoot
        )
    }

    private nonisolated static func aceStepModelStorageStatus(
        checkpointsPath: URL,
        repoID: String,
        components: [String]
    ) -> ModelStorageStatus {
        if let contractStatus = aceStepContractStorageStatus(
            checkpointsPath: checkpointsPath,
            expectedRepoID: repoID,
            expectedComponents: components
        ) {
            switch contractStatus {
            case .downloaded:
                break
            case .missing, .incomplete:
                return contractStatus
            }
        }
        return componentBundleStorageStatus(checkpointsPath: checkpointsPath, components: components)
    }

    private nonisolated static func componentBundleStorageStatus(
        checkpointsPath: URL,
        components: [String]
    ) -> ModelStorageStatus {
        let requiredComponents = components
        let checkpointsDir = checkpointsPath
        var foundAnyComponent = false
        var incompleteComponents: [String] = []

        guard !requiredComponents.isEmpty else {
            return .incomplete("Component bundle is missing component metadata.")
        }

        RuntimeDiagnostics.log("[RuntimeManager] Checking component bundle at \(checkpointsDir.path)")

        for component in requiredComponents {
            let componentPath = checkpointsDir.appendingPathComponent(component)
            if !FileManager.default.fileExists(atPath: componentPath.path) {
                RuntimeDiagnostics.log("[RuntimeManager] Component missing: \(componentPath.path)")
                incompleteComponents.append(component)
                continue
            }
            foundAnyComponent = true
            if !Self.containsModelWeights(at: componentPath) {
                RuntimeDiagnostics.log("[RuntimeManager] Component missing weight files: \(componentPath.path)")
                incompleteComponents.append(component)
                continue
            }
            RuntimeDiagnostics.log("[RuntimeManager] Component found with weights: \(componentPath.path)")
        }

        if !incompleteComponents.isEmpty {
            guard foundAnyComponent else { return .missing }
            return .incomplete("Model components are incomplete: \(incompleteComponents.joined(separator: ", ")). Repair will redownload missing components.")
        }

        RuntimeDiagnostics.log("[RuntimeManager] Component bundle fully downloaded at \(checkpointsDir.path)")
        return .downloaded
    }

    private nonisolated static func aceStepContractStorageStatus(
        checkpointsPath: URL,
        expectedRepoID: String,
        expectedComponents: [String]
    ) -> ModelStorageStatus? {
        let inProgressURL = checkpointsPath.appendingPathComponent(AceStepContractCompletionManifest.inProgressFilename)
        if FileManager.default.fileExists(atPath: inProgressURL.path) {
            return .incomplete("ACE-Step contract validation is incomplete. Repair will verify model code and checkpoints.")
        }

        let completionURL = checkpointsPath.appendingPathComponent(AceStepContractCompletionManifest.filename)
        guard FileManager.default.fileExists(atPath: completionURL.path) else {
            return nil
        }

        guard let data = try? Data(contentsOf: completionURL),
              let marker = try? JSONDecoder().decode(AceStepContractCompletionManifest.self, from: data),
              marker.schemaVersion == AceStepContractCompletionManifest.currentSchemaVersion,
              marker.repoID == expectedRepoID,
              Set(marker.requiredComponents) == Set(expectedComponents) else {
            return .incomplete("ACE-Step contract marker is invalid. Repair will verify model code and checkpoints.")
        }

        return .downloaded
    }

    private nonisolated static func nativeSnapshotStorageStatus(_ snapshotPath: URL) -> ModelStorageStatus? {
        let inProgressURL = snapshotPath.appendingPathComponent(NativeSnapshotCompletionManifest.inProgressFilename)
        if FileManager.default.fileExists(atPath: inProgressURL.path) {
            return .incomplete("Native model download is still incomplete. Repair will resume and verify missing files.")
        }

        let completionURL = snapshotPath.appendingPathComponent(NativeSnapshotCompletionManifest.filename)
        guard FileManager.default.fileExists(atPath: completionURL.path) else {
            return nil
        }

        guard let data = try? Data(contentsOf: completionURL),
              let marker = try? JSONDecoder().decode(NativeSnapshotCompletionManifest.self, from: data),
              marker.schemaVersion == NativeSnapshotCompletionManifest.currentSchemaVersion,
              !marker.files.isEmpty else {
            return .incomplete("Native model completion marker is invalid. Repair will verify and redownload missing files.")
        }

        let incompleteFiles = marker.manifestFiles.compactMap { file -> String? in
            let fileURL = snapshotPath.appendingPathComponent(file.path)
            return nativeSnapshotFileIsComplete(fileURL, expectedSize: file.size) ? nil : file.path
        }

        guard incompleteFiles.isEmpty else {
            let displayedFiles = incompleteFiles.prefix(3).joined(separator: ", ")
            let suffix = incompleteFiles.count > 3 ? " and \(incompleteFiles.count - 3) more" : ""
            return .incomplete("Native model snapshot is incomplete: \(displayedFiles)\(suffix). Repair will redownload missing files.")
        }

        return .downloaded
    }

    private nonisolated static func nativeSnapshotFileIsComplete(_ fileURL: URL, expectedSize: Int64?) -> Bool {
        let resolvedURL = fileURL.resolvingSymlinksInPath()
        let pathToCheck = resolvedURL.path == fileURL.path ? fileURL.path : resolvedURL.path
        guard FileManager.default.fileExists(atPath: pathToCheck),
              let attributes = try? FileManager.default.attributesOfItem(atPath: pathToCheck),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular,
              let fileSize = attributes[.size] as? NSNumber else {
            return false
        }

        guard let expectedSize else {
            return fileSize.int64Value > 0
        }
        return fileSize.int64Value == expectedSize
    }

    private nonisolated static func snapshotCandidates(modelCachePath: URL, snapshotsPath: URL) -> [URL] {
        var candidates: [URL] = []
        let refsPath = modelCachePath.appendingPathComponent("refs/main")
        if let revision = try? String(contentsOf: refsPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !revision.isEmpty {
            candidates.append(snapshotsPath.appendingPathComponent(revision))
        }

        guard let snapshots = try? FileManager.default.contentsOfDirectory(
            at: snapshotsPath,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return candidates
        }

        let sortedSnapshots = snapshots
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

        for snapshot in sortedSnapshots where !candidates.contains(snapshot) {
            candidates.append(snapshot)
        }
        return candidates
    }

    nonisolated static func containsModelWeights(at path: URL, maximumDepth: Int = 2) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: path,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            let relativeDepth = Self.relativePathDepth(fileURL, root: path)
            if relativeDepth > maximumDepth {
                if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard isModelWeightArtifact(fileURL),
                  modelWeightArtifactHasContent(fileURL) else {
                continue
            }
            return true
        }

        return false
    }

    private nonisolated static func weightIndexFiles(at path: URL, maximumDepth: Int = 3) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                at: path,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }

        var indexes: [URL] = []
        for case let fileURL as URL in enumerator {
            let relativeDepth = Self.relativePathDepth(fileURL, root: path)
            if relativeDepth > maximumDepth {
                if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if Self.isWeightIndexArtifact(fileURL) {
                indexes.append(fileURL)
            }
        }
        return indexes
    }

    private nonisolated static func declaredWeightFilesAreComplete(indexURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: indexURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = json["weight_map"] as? [String: String],
              !weightMap.isEmpty else {
            return false
        }

        let baseURL = indexURL.deletingLastPathComponent()
        let declaredFiles = Set(weightMap.values)
        guard !declaredFiles.isEmpty else { return false }

        for filename in declaredFiles {
            let weightURL = baseURL.appendingPathComponent(filename)
            guard Self.isModelWeightArtifact(weightURL),
                  Self.modelWeightArtifactHasContent(weightURL) else {
                return false
            }
        }
        return true
    }

    private nonisolated static func modelWeightArtifactHasContent(_ fileURL: URL) -> Bool {
        let resolvedURL = fileURL.resolvingSymlinksInPath()
        let pathToCheck = resolvedURL.path == fileURL.path ? fileURL.path : resolvedURL.path

        guard FileManager.default.fileExists(atPath: pathToCheck),
              let attributes = try? FileManager.default.attributesOfItem(atPath: pathToCheck),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular,
              let fileSize = attributes[.size] as? NSNumber else {
            return false
        }

        return fileSize.int64Value > 0
    }

    nonisolated static func snapshotContainsModelFiles(_ snapshotPath: URL) -> Bool {
        guard snapshotContainsModelMetadata(snapshotPath) else { return false }

        let indexes = weightIndexFiles(at: snapshotPath)
        if !indexes.isEmpty {
            return indexes.allSatisfy { declaredWeightFilesAreComplete(indexURL: $0) }
        }

        return containsModelWeights(at: snapshotPath)
    }

    private nonisolated static func snapshotContainsModelMetadata(_ snapshotPath: URL) -> Bool {
        let metadataFilenames = [
            "config.json",
            "model_index.json",
            "tokenizer_config.json",
            "preprocessor_config.json",
            "processor_config.json"
        ]

        for filename in metadataFilenames {
            if FileManager.default.fileExists(atPath: snapshotPath.appendingPathComponent(filename).path) {
                return true
            }
        }

        let subdirectories = ["transformer", "vae", "unet", "text_encoder"]
        for subdir in subdirectories {
            let subdirPath = snapshotPath.appendingPathComponent(subdir)
            for filename in metadataFilenames {
                if FileManager.default.fileExists(atPath: subdirPath.appendingPathComponent(filename).path) {
                    return true
                }
            }
        }

        return false
    }

    private nonisolated static func relativePathDepth(_ fileURL: URL, root: URL) -> Int {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return Int.max }

        let relative = filePath.dropFirst(rootPath.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { return 0 }
        return relative.split(separator: "/").count
    }

    private nonisolated static func isModelWeightArtifact(_ fileURL: URL) -> Bool {
        let filename = fileURL.lastPathComponent
        let knownWeightFilenames = Set([
            "model.safetensors",
            "pytorch_model.bin",
            "model.bin",
            "diffusion_pytorch_model.safetensors",
            "diffusion_pytorch_model.bin"
        ])

        if knownWeightFilenames.contains(filename) {
            return true
        }
        if filename.hasSuffix(".safetensors") || filename.hasSuffix(".gguf") || filename.hasSuffix(".ckpt") {
            return true
        }
        if filename.hasSuffix(".bin") {
            return filename.contains("model") || filename.contains("weight") || filename.contains("diffusion")
        }
        return false
    }

    private nonisolated static func isWeightIndexArtifact(_ fileURL: URL) -> Bool {
        let filename = fileURL.lastPathComponent
        return filename.hasSuffix(".safetensors.index.json")
            || filename.hasSuffix(".bin.index.json")
    }

    func estimatedModelSize(modelId: String) -> Double {
        ModelCapabilityProfile.embeddedProfile(modelId: modelId)?.downloadSizeGB ?? 5.0
    }
}


enum RuntimeError: LocalizedError {
    case bundleNotFound(String)
    case pythonNotFound(String)
    case bridgeScriptNotFound(String)
    case runtimeComponentNotFound(String, String)
    case pythonValidationFailed(String, String)
    case runtimeUpdateRequired(String, String)
    case initializationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .bundleNotFound(let path):
            return "Python runtime bundle not found at \(path)"
        case .pythonNotFound(let path):
            return "Python executable not found at \(path)"
        case .bridgeScriptNotFound(let path):
            return "Python bridge script not found at \(path)"
        case .runtimeComponentNotFound(let component, let path):
            return "\(component) not found at \(path). Rebuild the bundled runtime with ./Scripts/build-runtime-bundle.sh"
        case .pythonValidationFailed(let context, let details):
            return "\(context) is incomplete or broken. Rebuild the bundled runtime with ./Scripts/build-runtime-bundle.sh. \(details)"
        case .runtimeUpdateRequired(let modelName, let version):
            return "\(modelName) requires MLXtra runtime \(version) or newer. Install the runtime update in Models settings."
        case .initializationFailed(let message):
            return "Failed to initialize runtime: \(message)"
        }
    }
}
