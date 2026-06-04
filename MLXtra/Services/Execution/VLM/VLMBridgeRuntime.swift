import Foundation

@MainActor
protocol VLMBridgeRuntimeProviding: AnyObject {
    var checkpointsPath: URL { get }

    func initialize() async throws
    func pythonExecutablePath() -> URL
    func bridgeScriptPath() -> URL
    func pythonHomePath() -> URL
    func acestepPythonExecutablePath() -> URL
    func magentaPythonExecutablePath() -> URL
}

extension RuntimeManager: VLMBridgeRuntimeProviding {}
