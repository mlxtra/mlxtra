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
    enum RuntimeKind: Sendable {
        case aceStep
        case huggingFace
    }

    let kind: RuntimeKind
    let runtimeBundleURL: URL
    let pythonHomePath: URL
    let pythonExecutablePath: URL
    let helperPath: URL
    let importPackages: [String]
    let importContext: String
    let environment: [String: String]
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
        capabilities: [String] = []
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
            && (supportedModels?.contains(profile.modelId) ?? true)
    }
}

enum SHA256Checksum {
    static func hexDigest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hexDigest(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return hexDigest(for: data)
    }
}

@MainActor
final class RuntimeUpdateManager: ObservableObject {
    static let shared = RuntimeUpdateManager()

    enum InstallState: Equatable {
        case idle
        case checking
        case available(RuntimeReleaseAsset)
        case installing(Double?)
        case installed(String)
        case failed(String)
    }

    @Published private(set) var state: InstallState = .idle
    @Published private(set) var channel: ReleaseChannelManifest?

    var availableRuntime: RuntimeReleaseAsset? {
        if case .available(let asset) = state {
            return asset
        }
        return nil
    }

    func refreshStableChannel(
        channelURL: URL = ReleaseChannelManifest.defaultChannelURL,
        reportFailures: Bool = true
    ) async {
        state = .checking
        do {
            let (data, response) = try await URLSession.shared.data(from: channelURL)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw RuntimeUpdateError.channelUnavailable
            }

            let manifest = try JSONDecoder().decode(ReleaseChannelManifest.self, from: data)
            channel = manifest

            if let asset = bestRuntimeAsset(in: manifest) {
                state = .available(asset)
            } else {
                state = .idle
            }
        } catch {
            state = reportFailures ? .failed(error.localizedDescription) : .idle
        }
    }

    func installRuntime(_ asset: RuntimeReleaseAsset) async {
        state = .installing(nil)
        do {
            let archiveURL = try await fetchRuntimeArchive(asset)
            let actualChecksum = try SHA256Checksum.hexDigest(for: archiveURL)
            guard actualChecksum.caseInsensitiveCompare(asset.sha256) == .orderedSame else {
                throw RuntimeUpdateError.checksumMismatch
            }

            let installedURL = try RuntimeManager.installRuntimeArchive(archiveURL)
            guard let manifest = RuntimeManager.runtimeManifest(at: installedURL) else {
                throw RuntimeUpdateError.invalidRuntime
            }
            state = .installed(manifest.runtimeVersion)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func bestRuntimeAsset(in manifest: ReleaseChannelManifest) -> RuntimeReleaseAsset? {
        let current = RuntimeManager.activeRuntimeManifest()
        return manifest.runtimes
            .filter { $0.platform == "macos" && $0.arch == "arm64" }
            .filter { asset in
                guard let current else { return true }
                guard asset.compatibilityApi == current.compatibilityApi else { return false }
                return VersionComparator.compare(asset.version, current.runtimeVersion) == .orderedDescending
            }
            .sorted { VersionComparator.compare($0.version, $1.version) == .orderedDescending }
            .first
    }

    private func fetchRuntimeArchive(_ asset: RuntimeReleaseAsset) async throws -> URL {
        if asset.url.isFileURL {
            return asset.url
        }

        let (downloadURL, _) = try await URLSession.shared.download(from: asset.url)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXtra-runtime-\(UUID().uuidString)")
            .appendingPathExtension(asset.url.pathExtension.isEmpty ? "zip" : asset.url.pathExtension)
        try FileManager.default.moveItem(at: downloadURL, to: destination)
        return destination
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

        for path in candidates where fileManager.fileExists(atPath: path.path) {
            RuntimeDiagnostics.log("[RuntimeManager] Found bundled runtime bundle at: \(path.path)")
            return path
        }

        RuntimeDiagnostics.log("[RuntimeManager] Runtime bundle not found in expected locations, using default")
        return candidates[0]
    }

    nonisolated static func activeRuntimeManifest() -> RuntimeManifest? {
        runtimeManifest(at: activeRuntimeBundleURL())
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
            "python/Frameworks/Versions/3.12",
            "hf_download_helper.py",
            "acestep_download_helper.py",
            "runtime-manifest.json",
        ]
        return requiredFiles.allSatisfy { relativePath in
            fileManager.fileExists(atPath: runtimeURL.appendingPathComponent(relativePath).path)
        }
    }

    nonisolated static func installRuntimeArchive(
        _ archiveURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let installRoot = installedRuntimeURL(fileManager: fileManager).deletingLastPathComponent()
        let stagingURL = installRoot.appendingPathComponent("staging-\(UUID().uuidString)")
        let extractedURL = stagingURL.appendingPathComponent("extract")
        try fileManager.createDirectory(at: extractedURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingURL) }

        if archiveURL.hasDirectoryPath {
            try fileManager.copyItem(at: archiveURL, to: extractedURL.appendingPathComponent(archiveURL.lastPathComponent))
        } else if archiveURL.pathExtension.lowercased() == "zip" {
            try extractZipArchive(archiveURL, to: extractedURL)
        } else {
            throw RuntimeUpdateError.unsupportedArchive
        }

        let runtimeRoot = try normalizedRuntimeRoot(in: extractedURL, fileManager: fileManager)
        try validateExtractedRuntimeTree(runtimeRoot, fileManager: fileManager)
        guard isRuntimeBundleStructurallyValid(runtimeRoot, fileManager: fileManager) else {
            throw RuntimeUpdateError.invalidRuntime
        }

        let currentURL = installedRuntimeURL(fileManager: fileManager)
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
        return currentURL
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

            let huggingFaceHelper = huggingFaceDownloadHelperPath()
            try Self.validateRequiredFile(
                huggingFaceHelper,
                error: .runtimeComponentNotFound("Hugging Face download helper", huggingFaceHelper.path)
            )

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
            for: DownloadableModel(
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
        let context = try downloadSupportValidationContext(for: model)
        try Self.validateDownloadSupport(context)
    }

    func validateDownloadSupportOffMain(for model: DownloadableModel) async throws {
        let context = try downloadSupportValidationContext(for: model)
        try await Task.detached(priority: .utility) {
            try Self.validateDownloadSupport(context)
        }.value
    }

    private func downloadSupportValidationContext(for model: DownloadableModel) throws -> DownloadSupportValidationContext {
        guard model.isRuntimeCompatible else {
            throw RuntimeError.runtimeUpdateRequired(model.name, model.runtime.minVersion)
        }

        if model.source.usesComponentBundle {
            let aceStepPython = acestepPythonExecutablePath()
            let aceStepHelper = acestepDownloadHelperPath()
            return DownloadSupportValidationContext(
                kind: .aceStep,
                runtimeBundleURL: runtimeBundleURL,
                pythonHomePath: pythonHomePath(),
                pythonExecutablePath: aceStepPython,
                helperPath: aceStepHelper,
                importPackages: ["huggingface_hub", "tqdm", "acestep"],
                importContext: "ACE-Step download runtime",
                environment: bundledPythonEnvironment()
            )
        } else {
            let pythonPath = pythonExecutablePath()
            let huggingFaceHelper = huggingFaceDownloadHelperPath()
            return DownloadSupportValidationContext(
                kind: .huggingFace,
                runtimeBundleURL: runtimeBundleURL,
                pythonHomePath: pythonHomePath(),
                pythonExecutablePath: pythonPath,
                helperPath: huggingFaceHelper,
                importPackages: ["huggingface_hub", "tqdm"],
                importContext: "Hugging Face download runtime",
                environment: bundledPythonEnvironment()
            )
        }
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

        switch context.kind {
        case .aceStep:
            try validateRequiredFile(
                context.pythonExecutablePath,
                error: .runtimeComponentNotFound("ACE-Step Python executable", context.pythonExecutablePath.path),
                executable: true
            )
            try validateRequiredFile(
                context.helperPath,
                error: .runtimeComponentNotFound("ACE-Step download helper", context.helperPath.path)
            )
        case .huggingFace:
            try validateRequiredFile(
                context.pythonExecutablePath,
                error: .pythonNotFound(context.pythonExecutablePath.path),
                executable: true
            )
            try validateRequiredFile(
                context.helperPath,
                error: .runtimeComponentNotFound("Hugging Face download helper", context.helperPath.path)
            )
        }

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

    func huggingFaceDownloadHelperPath() -> URL {
        runtimeBundleURL.appendingPathComponent("hf_download_helper.py")
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

    /// Hugging Face models use the default HF cache so downloads can be shared with other apps.
    func modelStoragePath(modelId: String) -> URL {
        if modelId.hasPrefix("ACE-Step/") {
            return checkpointsPath
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
        if modelId.hasPrefix("ACE-Step/") {
            return aceStepModelStorageStatus(checkpointsPath: checkpointsPath)
        }

        let path = modelCachePath(modelId: modelId, huggingFaceCacheRoot: huggingFaceCacheRoot)
        RuntimeDiagnostics.log("[RuntimeManager] Checking HF cache for \(modelId) at \(path.path)")

        guard FileManager.default.fileExists(atPath: path.path),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: path.path),
              !contents.isEmpty else {
            RuntimeDiagnostics.log("[RuntimeManager] Model \(modelId) not in HF cache")
            return .missing
        }

        let snapshotsPath = path.appendingPathComponent("snapshots")
        if FileManager.default.fileExists(atPath: snapshotsPath.path) {
            for snapshotPath in Self.snapshotCandidates(modelCachePath: path, snapshotsPath: snapshotsPath) {
                if Self.snapshotContainsModelFiles(snapshotPath) {
                    RuntimeDiagnostics.log("[RuntimeManager] Model \(modelId) found in HF cache at \(snapshotPath.path)")
                    return .downloaded
                }
            }
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
            return componentBundleStorageStatus(
                checkpointsPath: checkpointsPath,
                components: model.source.components
            )
        }

        return modelStorageStatus(
            modelId: model.source.downloadRepository ?? model.modelId,
            checkpointsPath: checkpointsPath,
            huggingFaceCacheRoot: huggingFaceCacheRoot
        )
    }

    private nonisolated static func isAceStepModelDownloaded(checkpointsPath: URL) -> Bool {
        aceStepModelStorageStatus(checkpointsPath: checkpointsPath).isDownloaded
    }

    private nonisolated static func aceStepModelStorageStatus(checkpointsPath: URL) -> ModelStorageStatus {
        let aceStepComponents = ["acestep-v15-turbo", "vae", "Qwen3-Embedding-0.6B", "acestep-5Hz-lm-1.7B"]
        return componentBundleStorageStatus(checkpointsPath: checkpointsPath, components: aceStepComponents)
    }

    private nonisolated static func componentBundleStorageStatus(
        checkpointsPath: URL,
        components: [String]
    ) -> ModelStorageStatus {
        let requiredComponents = components.isEmpty
            ? ["acestep-v15-turbo", "vae", "Qwen3-Embedding-0.6B", "acestep-5Hz-lm-1.7B"]
            : components
        let checkpointsDir = checkpointsPath
        var foundAnyComponent = false
        var incompleteComponents: [String] = []

        RuntimeDiagnostics.log("[RuntimeManager] Checking ACE-Step model components at \(checkpointsDir.path)")

        for component in requiredComponents {
            let componentPath = checkpointsDir.appendingPathComponent(component)
            if !FileManager.default.fileExists(atPath: componentPath.path) {
                RuntimeDiagnostics.log("[RuntimeManager] ACE-Step component missing: \(componentPath.path)")
                incompleteComponents.append(component)
                continue
            }
            foundAnyComponent = true
            if !Self.containsModelWeights(at: componentPath) {
                RuntimeDiagnostics.log("[RuntimeManager] ACE-Step component missing weight files: \(componentPath.path)")
                incompleteComponents.append(component)
                continue
            }
            RuntimeDiagnostics.log("[RuntimeManager] ACE-Step component found with weights: \(componentPath.path)")
        }

        if !incompleteComponents.isEmpty {
            guard foundAnyComponent else { return .missing }
            return .incomplete("ACE-Step checkpoints are incomplete: \(incompleteComponents.joined(separator: ", ")). Repair will redownload missing components.")
        }

        RuntimeDiagnostics.log("[RuntimeManager] ACE-Step model fully downloaded at \(checkpointsDir.path)")
        return .downloaded
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
        if modelId.contains("Qwen3.5-9B") {
            return 5.6
        } else if modelId.contains("gemma-4") {
            return 3.0
        } else if modelId.contains("Qwen3.5-2B") {
            return 1.5
        } else if modelId.contains("FLUX.2-klein-4B") {
            return 15.0
        } else if modelId.contains("kugelaudio-0-open") {
            return 15.0
        } else if modelId.contains("acestep-v15-xl") {
            return 19.0
        } else if modelId.contains("acestep-v15-turbo-continuous") {
            return 4.8
        } else if modelId.contains("acestep-v15") {
            return 5.0
        }
        return 5.0 // Default estimate
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
