import Foundation
import Combine

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
