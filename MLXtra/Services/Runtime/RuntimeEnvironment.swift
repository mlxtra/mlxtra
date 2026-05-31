import Foundation

private struct DownloadSupportValidationContext: Sendable {
    let runtimeBundleURL: URL
    let pythonHomePath: URL
    let pythonExecutablePath: URL
    let helperPath: URL
    let importPackages: [String]
    let importContext: String
    let environment: [String: String]
}

extension RuntimeManager {
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
            runtimeBundleURL: activeRuntimeURL,
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
            throw RuntimeError.pythonValidationFailed(
                context,
                details.isEmpty ? "Python exited with status \(process.terminationStatus)" : details
            )
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

    nonisolated static func validateRequiredDirectory(_ url: URL, error: RuntimeError) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw error
        }
    }

    nonisolated static func validateRequiredFile(_ url: URL, error: RuntimeError, executable: Bool = false) throws {
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
        activeRuntimeURL.appendingPathComponent("venv/bin/python")
    }

    func acestepPythonExecutablePath() -> URL {
        activeRuntimeURL.appendingPathComponent("acestep-venv/bin/python")
    }

    func acestepDownloadHelperPath() -> URL {
        activeRuntimeURL.appendingPathComponent("acestep_download_helper.py")
    }

    func pythonSitePackagesPath() -> URL {
        for version in ["python3.13", "python3.12", "python3.11"] {
            let path = activeRuntimeURL.appendingPathComponent("venv/lib/\(version)/site-packages")
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }
        return activeRuntimeURL.appendingPathComponent("venv/lib/python3.12/site-packages")
    }

    /// This must be set as PYTHONHOME when launching the bundled Python so
    /// it can locate the standard library and C extension modules.
    func pythonHomePath() -> URL {
        activeRuntimeURL
            .appendingPathComponent("python/Frameworks/Versions/3.12")
    }

    func bridgeScriptPath() -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/python_bridge.py")
    }

    private var activeRuntimeURL: URL {
        Self.activeRuntimeBundleURL()
    }
}
