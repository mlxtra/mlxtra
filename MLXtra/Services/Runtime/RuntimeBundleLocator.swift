import Foundation

extension RuntimeManager {
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
}
