import Foundation
import Combine

/// Manages Python runtime lifecycle and bundle
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
    
    private var runtimeBundleURL: URL {
        // Try multiple locations for the runtime bundle
        let possiblePaths = [
            // Bundled app path
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/runtime/macos-arm64"),
            // Xcode build path (development)
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Resources/runtime/macos-arm64"),
            // Project root path
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/runtime/macos-arm64"),
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path.path) {
                print("[RuntimeManager] Found runtime bundle at: \(path.path)")
                return path
            }
        }

        // Return default path even if not found (error will be thrown later)
        print("[RuntimeManager] Runtime bundle not found in expected locations, using default")
        return possiblePaths[0]
    }
    
    private var appSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MLXHub")
    }

    var checkpointsPath: URL {
        appSupportURL.appendingPathComponent("checkpoints")
    }
    
    /// Initialize the Python runtime
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
            try validateRequiredDirectory(bundlePath, error: .bundleNotFound(bundlePath.path))

            let pythonHome = pythonHomePath()
            try validateRequiredDirectory(
                pythonHome,
                error: .runtimeComponentNotFound("Bundled Python home", pythonHome.path)
            )

            let pythonPath = pythonExecutablePath()
            try validateRequiredFile(pythonPath, error: .pythonNotFound(pythonPath.path), executable: true)

            let bridgePath = bridgeScriptPath()
            try validateRequiredFile(bridgePath, error: .bridgeScriptNotFound(bridgePath.path))

            let huggingFaceHelper = huggingFaceDownloadHelperPath()
            try validateRequiredFile(
                huggingFaceHelper,
                error: .runtimeComponentNotFound("Hugging Face download helper", huggingFaceHelper.path)
            )

            let aceStepPython = acestepPythonExecutablePath()
            try validateRequiredFile(
                aceStepPython,
                error: .runtimeComponentNotFound("ACE-Step Python executable", aceStepPython.path),
                executable: true
            )

            let aceStepHelper = acestepDownloadHelperPath()
            try validateRequiredFile(
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

    /// Validate only the runtime pieces needed to download this model.
    /// Downloading should not require unrelated model runtimes to be present.
    func validateDownloadSupport(for modelId: String) throws {
        let bundlePath = runtimeBundleURL
        try validateRequiredDirectory(bundlePath, error: .bundleNotFound(bundlePath.path))

        let pythonHome = pythonHomePath()
        try validateRequiredDirectory(
            pythonHome,
            error: .runtimeComponentNotFound("Bundled Python home", pythonHome.path)
        )

        if modelId.hasPrefix("ACE-Step/") {
            let aceStepPython = acestepPythonExecutablePath()
            try validateRequiredFile(
                aceStepPython,
                error: .runtimeComponentNotFound("ACE-Step Python executable", aceStepPython.path),
                executable: true
            )

            let aceStepHelper = acestepDownloadHelperPath()
            try validateRequiredFile(
                aceStepHelper,
                error: .runtimeComponentNotFound("ACE-Step download helper", aceStepHelper.path)
            )

            try validatePythonImports(
                pythonPath: aceStepPython,
                packages: ["huggingface_hub", "tqdm", "acestep"],
                context: "ACE-Step download runtime"
            )
        } else {
            let pythonPath = pythonExecutablePath()
            try validateRequiredFile(pythonPath, error: .pythonNotFound(pythonPath.path), executable: true)

            let huggingFaceHelper = huggingFaceDownloadHelperPath()
            try validateRequiredFile(
                huggingFaceHelper,
                error: .runtimeComponentNotFound("Hugging Face download helper", huggingFaceHelper.path)
            )

            try validatePythonImports(
                pythonPath: pythonPath,
                packages: ["huggingface_hub", "tqdm"],
                context: "Hugging Face download runtime"
            )
        }
    }

    private func validatePythonImports(pythonPath: URL, packages: [String], context: String) throws {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = pythonPath
        process.arguments = [
            "-c",
            "import importlib, sys; [importlib.import_module(package) for package in sys.argv[1:]]",
        ] + packages
        process.environment = bundledPythonEnvironment()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw RuntimeError.pythonValidationFailed(context, error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let details = (stderr.isEmpty ? stdout : stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RuntimeError.pythonValidationFailed(context, details.isEmpty ? "Python exited with status \(process.terminationStatus)" : details)
        }
    }

    private func bundledPythonEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["PYTHONPATH", "VIRTUAL_ENV", "CONDA_PREFIX", "CONDA_DEFAULT_ENV", "PYENV_ROOT", "PYENV_VERSION"] {
            environment.removeValue(forKey: key)
        }
        environment["PYTHONHOME"] = pythonHomePath().path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return environment
    }

    private func validateRequiredDirectory(_ url: URL, error: RuntimeError) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw error
        }
    }

    private func validateRequiredFile(_ url: URL, error: RuntimeError, executable: Bool = false) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw error
        }

        if executable && !FileManager.default.isExecutableFile(atPath: url.path) {
            throw error
        }
    }
    
    /// Get path to Python executable
    func pythonExecutablePath() -> URL {
        runtimeBundleURL.appendingPathComponent("venv/bin/python")
    }

    /// Get path to ACE-Step Python executable (separate venv)
    func acestepPythonExecutablePath() -> URL {
        runtimeBundleURL.appendingPathComponent("acestep-venv/bin/python")
    }

    /// Get path to ACE-Step download helper script
    func acestepDownloadHelperPath() -> URL {
        runtimeBundleURL.appendingPathComponent("acestep_download_helper.py")
    }

    /// Get path to Hugging Face download helper script
    func huggingFaceDownloadHelperPath() -> URL {
        runtimeBundleURL.appendingPathComponent("hf_download_helper.py")
    }
    
    /// Get Python version directory
    func pythonSitePackagesPath() -> URL {
        // Try different Python versions
        for version in ["python3.13", "python3.12", "python3.11"] {
            let path = runtimeBundleURL.appendingPathComponent("venv/lib/\(version)/site-packages")
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }
        // Default fallback
        return runtimeBundleURL.appendingPathComponent("venv/lib/python3.12/site-packages")
    }
    
    /// Get path to the bundled Python framework home.
    /// This must be set as PYTHONHOME when launching the bundled Python so
    /// it can locate the standard library and C extension modules.
    func pythonHomePath() -> URL {
        runtimeBundleURL
            .appendingPathComponent("python/Frameworks/Versions/3.12")
    }

    /// Get path to bridge script
    func bridgeScriptPath() -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/python_bridge.py")
    }
    
    /// Get path to a specific model in HF cache
    func modelCachePath(modelId: String) -> URL {
        Self.modelCachePath(modelId: modelId)
    }

    nonisolated static func modelCachePath(modelId: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent("models--" + modelId.replacingOccurrences(of: "/", with: "--"))
    }

    /// Get the expected local storage path for a model.
    /// Hugging Face models use the default HF cache so downloads can be shared with other apps.
    func modelStoragePath(modelId: String) -> URL {
        if modelId.hasPrefix("ACE-Step/") {
            return checkpointsPath
        }
        return modelCachePath(modelId: modelId)
    }

    /// Check if model is already downloaded (HF cache)
    func isModelDownloaded(modelId: String) -> Bool {
        Self.isModelDownloaded(modelId: modelId, checkpointsPath: checkpointsPath)
    }

    nonisolated static func isModelDownloaded(modelId: String, checkpointsPath: URL) -> Bool {
        // Special handling for ACE-Step models - check component subdirectories under checkpoints/
        if modelId.hasPrefix("ACE-Step/") {
            return isAceStepModelDownloaded(checkpointsPath: checkpointsPath)
        }

        // For other models, check HF cache structure
        let path = modelCachePath(modelId: modelId)
        print("[RuntimeManager] Checking HF cache for \(modelId) at \(path.path)")

        // Check if directory exists and has contents
        guard FileManager.default.fileExists(atPath: path.path),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: path.path),
              !contents.isEmpty else {
            print("[RuntimeManager] Model \(modelId) not in HF cache")
            return false
        }

        // Check for snapshots subdirectory (standard HF cache structure)
        let snapshotsPath = path.appendingPathComponent("snapshots")
        if FileManager.default.fileExists(atPath: snapshotsPath.path) {
            for snapshotPath in Self.snapshotCandidates(modelCachePath: path, snapshotsPath: snapshotsPath) {
                if Self.snapshotContainsModelFiles(snapshotPath) {
                    print("[RuntimeManager] Model \(modelId) found in HF cache at \(snapshotPath.path)")
                    return true
                }
            }
        }

        print("[RuntimeManager] Model \(modelId) not in HF cache")
        return false
    }

/// ACE-Step models download to component subdirectories under checkpoints/
	/// Check if all main model components exist and contain actual weight files
	private nonisolated static func isAceStepModelDownloaded(checkpointsPath: URL) -> Bool {
		let aceStepComponents = ["acestep-v15-turbo", "vae", "Qwen3-Embedding-0.6B", "acestep-5Hz-lm-1.7B"]
		let checkpointsDir = checkpointsPath

		print("[RuntimeManager] Checking ACE-Step model components at \(checkpointsDir.path)")

		for component in aceStepComponents {
			let componentPath = checkpointsDir.appendingPathComponent(component)
			if !FileManager.default.fileExists(atPath: componentPath.path) {
				print("[RuntimeManager] ACE-Step component missing: \(componentPath.path)")
				return false
			}
			if !Self.containsModelWeights(at: componentPath) {
				print("[RuntimeManager] ACE-Step component missing weight files: \(componentPath.path)")
				return false
			}
			print("[RuntimeManager] ACE-Step component found with weights: \(componentPath.path)")
		}

		print("[RuntimeManager] ACE-Step model fully downloaded at \(checkpointsDir.path)")
		return true
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
            snapshotContainsModelMetadata(snapshotPath) && containsModelWeights(at: snapshotPath)
		}

        private nonisolated static func snapshotContainsModelMetadata(_ snapshotPath: URL) -> Bool {
            let metadataFilenames = [
                "config.json",
                "model_index.json",
                "tokenizer_config.json",
                "preprocessor_config.json",
                "processor_config.json"
            ]

            // First check the root directory (standard for LLMs/VLMs)
            for filename in metadataFilenames {
                if FileManager.default.fileExists(atPath: snapshotPath.appendingPathComponent(filename).path) {
                    return true
                }
            }

            // Fallback: check common subdirectories (standard for multi-component models like FLUX)
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
			"model.safetensors.index.json",
			"pytorch_model.bin",
			"pytorch_model.bin.index.json",
			"model.bin",
			"diffusion_pytorch_model.safetensors",
			"diffusion_pytorch_model.safetensors.index.json",
			"diffusion_pytorch_model.bin",
			"diffusion_pytorch_model.bin.index.json"
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
    
    /// Get estimated model size
    func estimatedModelSize(modelId: String) -> Double {
        // These are rough estimates in GB
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

// MARK: - Errors

enum RuntimeError: LocalizedError {
    case bundleNotFound(String)
    case pythonNotFound(String)
    case bridgeScriptNotFound(String)
    case runtimeComponentNotFound(String, String)
    case pythonValidationFailed(String, String)
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
        case .initializationFailed(let message):
            return "Failed to initialize runtime: \(message)"
        }
    }
}
