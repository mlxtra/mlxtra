import Foundation

enum VLMBridgeEnvironment {
    static let removedHostPythonKeys = [
        "PYTHONPATH",
        "VIRTUAL_ENV",
        "CONDA_PREFIX",
        "CONDA_DEFAULT_ENV",
        "PYENV_ROOT",
        "PYENV_VERSION"
    ]

    static func make(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        pythonHomePath: URL,
        checkpointsPath: URL,
        acestepPythonPath: URL,
        magentaPythonPath: URL,
        bridgeDebugEnabled: Bool,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var environment = baseEnvironment

        for key in removedHostPythonKeys {
            environment.removeValue(forKey: key)
        }

        environment["PYTHONHOME"] = pythonHomePath.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"

        if bridgeDebugEnabled {
            environment["MLXTRA_BRIDGE_DEBUG"] = "1"
        } else {
            environment.removeValue(forKey: "MLXTRA_BRIDGE_DEBUG")
        }

        environment["HF_HOME"] = homeDirectory
            .appendingPathComponent(".cache/huggingface")
            .path
        environment["HF_HUB_CACHE"] = homeDirectory
            .appendingPathComponent(".cache/huggingface/hub")
            .path
        environment["ACESTEP_CHECKPOINTS_DIR"] = checkpointsPath.path
        environment["ACESTEP_PYTHON"] = acestepPythonPath.path
        environment["MAGENTA_RT_CHECKPOINTS_DIR"] = checkpointsPath.path
        environment["MAGENTA_RT_PYTHON"] = magentaPythonPath.path

        environment["MTL_DEBUG_LAYER"] = "0"
        environment["MTL_SHADER_VALIDATION"] = "0"

        return environment
    }
}
