import Foundation

private final class RuntimeManifestCache: @unchecked Sendable {
    static let shared = RuntimeManifestCache()

    private let lock = NSLock()
    private var manifests: [String: RuntimeManifest] = [:]

    func manifest(at runtimeURL: URL, component: RuntimeComponent) -> RuntimeManifest? {
        let key = cacheKey(runtimeURL: runtimeURL, component: component)
        lock.lock()
        if let cached = manifests[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let manifestURL = runtimeURL.appendingPathComponent(component.manifestFilename)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(RuntimeManifest.self, from: data) else {
            return nil
        }

        lock.lock()
        manifests[key] = manifest
        lock.unlock()
        return manifest
    }

    func invalidateAll() {
        lock.lock()
        manifests.removeAll()
        lock.unlock()
    }

    private func cacheKey(runtimeURL: URL, component: RuntimeComponent) -> String {
        "\(runtimeURL.standardizedFileURL.path)#\(component.rawValue)"
    }
}

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

    nonisolated static func bundledRuntimeComponentCandidates(
        component: RuntimeComponent,
        bundle: Bundle = .main
    ) -> [URL] {
        switch component {
        case .base:
            return bundledRuntimeCandidates(bundle: bundle)
        case .music:
            return uniqueRuntimeURLs(
                bundledRuntimeCandidates(bundle: bundle).map { baseCandidate in
                    baseCandidate
                        .deletingLastPathComponent()
                        .appendingPathComponent("music-macos-arm64")
                }
            )
        }
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

    nonisolated static func activeRuntimeComponentURL(
        component: RuntimeComponent,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL {
        let baseRuntime = activeRuntimeBundleURL(bundle: bundle, fileManager: fileManager)
        return preferredRuntimeComponentURL(
            component,
            baseRuntime: baseRuntime,
            bundledCandidates: bundledRuntimeComponentCandidates(component: component, bundle: bundle),
            fileManager: fileManager
        )
    }

    nonisolated static func preferredRuntimeBundleURL(
        installed: URL,
        bundledCandidates candidates: [URL],
        fileManager: FileManager = .default
    ) -> URL {
        let validRuntimes = ([installed] + candidates).compactMap { path -> (url: URL, manifest: RuntimeManifest, isInstalled: Bool)? in
            guard isRuntimeBundleStructurallyValid(path, fileManager: fileManager),
                  let manifest = runtimeManifest(at: path) else {
                return nil
            }
            return (path, manifest, path == installed)
        }

        if let selected = validRuntimes.max(by: { lhs, rhs in
            let versionOrder = VersionComparator.compare(lhs.manifest.runtimeVersion, rhs.manifest.runtimeVersion)
            if versionOrder != .orderedSame {
                return versionOrder == .orderedAscending
            }
            return !lhs.isInstalled && rhs.isInstalled
        }) {
            if selected.isInstalled {
                RuntimeDiagnostics.log("[RuntimeManager] Using installed runtime bundle at: \(selected.url.path)")
            } else {
                RuntimeDiagnostics.log("[RuntimeManager] Found newer bundled runtime bundle at: \(selected.url.path)")
            }
            return selected.url
        }

        RuntimeDiagnostics.log("[RuntimeManager] Runtime bundle not found in expected locations, using default")
        return candidates[0]
    }

    nonisolated static func preferredRuntimeComponentURL(
        _ component: RuntimeComponent,
        baseRuntime: URL,
        bundledCandidates: [URL],
        fileManager: FileManager = .default
    ) -> URL {
        guard component != .base else {
            return baseRuntime
        }

        let siblingRuntime = baseRuntime
            .deletingLastPathComponent()
            .appendingPathComponent("music-macos-arm64")
        let candidates = uniqueRuntimeURLs([baseRuntime, siblingRuntime] + bundledCandidates)

        if let selected = candidates.first(where: {
            isRuntimeComponentStructurallyValid(component, at: $0, fileManager: fileManager)
        }) {
            if selected == baseRuntime {
                RuntimeDiagnostics.log("[RuntimeManager] Using \(component.rawValue) runtime component at: \(selected.path)")
            } else {
                RuntimeDiagnostics.log("[RuntimeManager] Found split \(component.rawValue) runtime component at: \(selected.path)")
            }
            return selected
        }

        RuntimeDiagnostics.log("[RuntimeManager] \(component.displayName) component not found, using base runtime path")
        return baseRuntime
    }

    nonisolated static func activeRuntimeManifest() -> RuntimeManifest? {
        activeRuntimeManifest(component: .base)
    }

    nonisolated static func activeRuntimeManifest(component: RuntimeComponent) -> RuntimeManifest? {
        let baseRuntimeURL = activeRuntimeBundleURL()
        guard isRuntimeBundleStructurallyValid(baseRuntimeURL) else {
            return nil
        }
        switch component {
        case .base:
            return runtimeManifest(at: baseRuntimeURL)
        case .music:
            let musicRuntimeURL = activeRuntimeComponentURL(component: .music)
            if isRuntimeComponentStructurallyValid(.music, at: musicRuntimeURL),
               let manifest = runtimeManifest(at: musicRuntimeURL, component: .music) {
                return manifest
            }
            return legacyMusicRuntimeManifest(at: baseRuntimeURL)
        }
    }

    nonisolated static func runtimeManifest(at runtimeURL: URL) -> RuntimeManifest? {
        runtimeManifest(at: runtimeURL, component: .base)
    }

    nonisolated static func runtimeManifest(at runtimeURL: URL, component: RuntimeComponent) -> RuntimeManifest? {
        RuntimeManifestCache.shared.manifest(at: runtimeURL, component: component)
    }

    nonisolated static func invalidateRuntimeManifestCache() {
        RuntimeManifestCache.shared.invalidateAll()
    }

    nonisolated static func effectiveRuntimeManifest() -> RuntimeManifest? {
        guard let base = activeRuntimeManifest(component: .base) else {
            return nil
        }
        guard let music = activeRuntimeManifest(component: .music) else {
            return base
        }
        let supportedBackends = Array(Set(base.supportedBackends).union(music.supportedBackends))
            .sorted { $0.rawValue < $1.rawValue }
        let capabilities = Array(Set(base.capabilities).union(music.capabilities)).sorted()
        return RuntimeManifest(
            runtimeVersion: base.runtimeVersion,
            compatibilityApi: base.compatibilityApi,
            platform: base.platform,
            arch: base.arch,
            component: .base,
            channel: base.channel,
            pythonVersion: base.pythonVersion,
            pythonPath: base.pythonPath,
            executables: base.executables,
            packages: base.packages,
            isolatedPackages: Array(Set(base.isolatedPackages).union(music.isolatedPackages)).sorted(),
            supportedModels: mergeSupportedModels(base.supportedModels, music.supportedModels),
            supportedBackends: supportedBackends,
            capabilities: capabilities,
            imageRuntimes: base.imageRuntimes,
            audioRuntimes: base.audioRuntimes
        )
    }

    nonisolated static func isRuntimeBundleStructurallyValid(
        _ runtimeURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: runtimeURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              runtimeManifest(at: runtimeURL)?.component == .base else {
            return false
        }

        let requiredFiles = [
            "venv/bin/python",
            "python/Frameworks/Versions/3.12",
            "runtime-manifest.json",
        ]
        guard requiredFiles.allSatisfy({ relativePath in
            fileManager.fileExists(atPath: runtimeURL.appendingPathComponent(relativePath).path)
        }) else {
            return false
        }

        let requiredExecutables = [
            "venv/bin/python",
        ]
        return requiredExecutables.allSatisfy { relativePath in
            fileManager.isExecutableFile(atPath: runtimeURL.appendingPathComponent(relativePath).path)
        }
    }

    nonisolated static func isRuntimeComponentStructurallyValid(
        _ component: RuntimeComponent,
        at runtimeURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        switch component {
        case .base:
            return isRuntimeBundleStructurallyValid(runtimeURL, fileManager: fileManager)
        case .music:
            guard let manifest = runtimeManifest(at: runtimeURL, component: .music),
                  manifest.component == .music else {
                return false
            }
            var requiredFiles = [
                "acestep-venv/bin/python",
                "acestep_download_helper.py",
                RuntimeComponent.music.manifestFilename,
            ]
            var requiredExecutables = [
                "acestep-venv/bin/python",
            ]
            if manifest.requiresMagentaRuntime {
                requiredFiles.append("magenta-venv/bin/python")
                requiredExecutables.append("magenta-venv/bin/python")
            }
            guard requiredFiles.allSatisfy({ relativePath in
                fileManager.fileExists(atPath: runtimeURL.appendingPathComponent(relativePath).path)
            }) else {
                return false
            }
            return requiredExecutables.allSatisfy {
                fileManager.isExecutableFile(atPath: runtimeURL.appendingPathComponent($0).path)
            }
        }
    }

    private nonisolated static func uniqueRuntimeURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var unique: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { continue }
            unique.append(url)
        }
        return unique
    }

    private nonisolated static func legacyMusicRuntimeManifest(at runtimeURL: URL) -> RuntimeManifest? {
        guard let base = runtimeManifest(at: runtimeURL),
              base.supports(backend: .music),
              base.capabilities.contains("music-generation"),
              fileManagerForLegacyMusic.fileExists(atPath: runtimeURL.appendingPathComponent("acestep-venv/bin/python").path),
              fileManagerForLegacyMusic.isExecutableFile(atPath: runtimeURL.appendingPathComponent("acestep-venv/bin/python").path),
              fileManagerForLegacyMusic.fileExists(atPath: runtimeURL.appendingPathComponent("acestep_download_helper.py").path) else {
            return nil
        }
        return RuntimeManifest(
            runtimeVersion: base.runtimeVersion,
            compatibilityApi: base.compatibilityApi,
            platform: base.platform,
            arch: base.arch,
            component: .music,
            channel: base.channel,
            pythonVersion: base.pythonVersion,
            pythonPath: "acestep-venv/bin/python3",
            executables: [
                "python": "acestep-venv/bin/python3",
            ],
            packages: [],
            isolatedPackages: base.isolatedPackages,
            supportedModels: base.supportedModels,
            supportedBackends: [.music],
            capabilities: ["music-generation"]
        )
    }

    private nonisolated static var fileManagerForLegacyMusic: FileManager {
        .default
    }

    private nonisolated static func mergeSupportedModels(_ lhs: [String]?, _ rhs: [String]?) -> [String]? {
        switch (lhs, rhs) {
        case (nil, _), (_, nil):
            return nil
        case (.some(let lhs), .some(let rhs)):
            return Array(Set(lhs).union(rhs)).sorted()
        }
    }
}
