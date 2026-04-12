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
    
    /// Get path to a specific model in cache
    func modelCachePath(modelId: String) -> URL {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent("models--" + modelId.replacingOccurrences(of: "/", with: "--"))
    }
    
    /// Check if model is already downloaded
    func isModelDownloaded(modelId: String) -> Bool {
        let path = modelCachePath(modelId: modelId)
        // Check for model weights file presence
        let snapshotsPath = path.appendingPathComponent("snapshots")

        // Check if snapshots directory exists and has files
        if FileManager.default.fileExists(atPath: snapshotsPath.path) {
            if let snapshots = try? FileManager.default.contentsOfDirectory(atPath: snapshotsPath.path),
               !snapshots.isEmpty {
                // Check if any snapshot has model files
                for snapshot in snapshots {
                    let snapshotPath = snapshotsPath.appendingPathComponent(snapshot)
                    if let contents = try? FileManager.default.contentsOfDirectory(atPath: snapshotPath.path),
                       contents.contains(where: { $0.contains("safetensors") || $0 == "model.safetensors.index.json" }) {
                        print("[RuntimeManager] Model \(modelId) found at \(snapshotPath.path)")
                        return true
                    }
                }
            }
        }

        print("[RuntimeManager] Model \(modelId) not fully downloaded yet")
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
