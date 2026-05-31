import Foundation

enum RuntimeDiagnostics {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MLXTRA_RUNTIME_DEBUG"] == "1"
            || UserDefaults.standard.bool(forKey: "MLXtra.runtimeDebug")
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print(message())
    }
}
