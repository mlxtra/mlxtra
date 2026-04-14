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
        guard state == .notInitialized else { return }
        
        state = .checkingBundle
        loadingMessage = "Checking Python runtime..."
        
        // Check if Python runtime exists in bundle
        guard FileManager.default.fileExists(atPath: runtimeBundleURL.path) else {
            throw RuntimeError.bundleNotFound(runtimeBundleURL.path)
        }
        
        // Check if Python executable exists
        let pythonPath = pythonExecutablePath()
        guard FileManager.default.fileExists(atPath: pythonPath.path) else {
            throw RuntimeError.pythonNotFound(pythonPath.path)
        }
        
        // Check if bridge script exists
        let bridgePath = bridgeScriptPath()
        guard FileManager.default.fileExists(atPath: bridgePath.path) else {
            throw RuntimeError.bridgeScriptNotFound(bridgePath.path)
        }
        
        state = .ready
        loadingMessage = ""
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
        return runtimeBundleURL.appendingPathComponent("venv/lib/python3.13/site-packages")
    }
    
    /// Get path to bridge script
    func bridgeScriptPath() -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/python_bridge.py")
    }
    
/// Get path to a specific model in HF cache
    func modelCachePath(modelId: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent("models--" + modelId.replacingOccurrences(of: "/", with: "--"))
    }

    /// Check if model is already downloaded (HF cache)
    func isModelDownloaded(modelId: String) -> Bool {
        // Special handling for ACE-Step models - check component subdirectories under checkpoints/
        if modelId.hasPrefix("ACE-Step/") {
            return isAceStepModelDownloaded()
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
            if let snapshots = try? FileManager.default.contentsOfDirectory(atPath: snapshotsPath.path),
                !snapshots.isEmpty {
                for snapshot in snapshots {
                    let snapshotPath = snapshotsPath.appendingPathComponent(snapshot)
                    if snapshotContainsModelFiles(snapshotPath) {
                        print("[RuntimeManager] Model \(modelId) found in HF cache at \(snapshotPath.path)")
                        return true
                    }
                }
            }
        }

        print("[RuntimeManager] Model \(modelId) not in HF cache")
        return false
    }

    /// ACE-Step models download to component subdirectories under checkpoints/
    /// Check if all main model components exist
    private func isAceStepModelDownloaded() -> Bool {
        let aceStepComponents = ["acestep-v15-turbo", "vae", "Qwen3-Embedding-0.6B", "acestep-5Hz-lm-1.7B"]
        let checkpointsDir = checkpointsPath

        print("[RuntimeManager] Checking ACE-Step model components at \(checkpointsDir.path)")

        for component in aceStepComponents {
            let componentPath = checkpointsDir.appendingPathComponent(component)
            if !FileManager.default.fileExists(atPath: componentPath.path) {
                print("[RuntimeManager] ACE-Step component missing: \(componentPath.path)")
                return false
            }
            // Check if component directory has any files
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: componentPath.path),
               contents.isEmpty {
                print("[RuntimeManager] ACE-Step component empty: \(componentPath.path)")
                return false
            }
            print("[RuntimeManager] ACE-Step component found: \(componentPath.path)")
        }

        print("[RuntimeManager] ACE-Step model fully downloaded at \(checkpointsDir.path)")
        return true
    }

    private func snapshotContainsModelFiles(_ snapshotPath: URL) -> Bool {
        // Just check if the snapshots directory exists and has any snapshot folders
        // In HuggingFace's cache structure, presence of snapshot = downloaded
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: snapshotPath,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return false
        }
        return !contents.isEmpty
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

enum RuntimeError: Error {
    case bundleNotFound(String)
    case pythonNotFound(String)
    case bridgeScriptNotFound(String)
    case initializationFailed(String)
    
    var localizedDescription: String {
        switch self {
        case .bundleNotFound(let path):
            return "Python runtime bundle not found at \(path)"
        case .pythonNotFound(let path):
            return "Python executable not found at \(path)"
        case .bridgeScriptNotFound(let path):
            return "Python bridge script not found at \(path)"
        case .initializationFailed(let message):
            return "Failed to initialize runtime: \(message)"
        }
    }
}
