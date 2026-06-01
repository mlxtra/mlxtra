import Foundation

extension RuntimeManager {
    nonisolated static func installRuntimeArchive(
        _ archiveURL: URL,
        fileManager: FileManager = .default,
        progressHandler: @escaping @Sendable (RuntimeActivationProgress) -> Void = { _ in }
    ) throws -> URL {
        let installRoot = installedRuntimeURL(fileManager: fileManager).deletingLastPathComponent()
        return try installRuntimeArchive(
            archiveURL,
            installRoot: installRoot,
            fileManager: fileManager,
            progressHandler: progressHandler
        )
    }

    nonisolated static func installRuntimeComponentArchive(
        _ archiveURL: URL,
        component: RuntimeComponent,
        fileManager: FileManager = .default,
        progressHandler: @escaping @Sendable (RuntimeActivationProgress) -> Void = { _ in }
    ) throws -> URL {
        guard component != .base else {
            return try installRuntimeArchive(
                archiveURL,
                fileManager: fileManager,
                progressHandler: progressHandler
            )
        }

        let installRoot = installedRuntimeURL(fileManager: fileManager).deletingLastPathComponent()
        let currentURL = installRoot.appendingPathComponent("current")
        try prepareInstalledBaseRuntimeIfNeeded(currentURL: currentURL, fileManager: fileManager)
        return try installRuntimeComponentArchive(
            archiveURL,
            component: component,
            activeRuntimeRoot: currentURL,
            installRoot: installRoot,
            fileManager: fileManager,
            progressHandler: progressHandler
        )
    }

    nonisolated static func installRuntimeArchive(
        _ archiveURL: URL,
        installRoot: URL,
        fileManager: FileManager = .default,
        progressHandler: @escaping @Sendable (RuntimeActivationProgress) -> Void = { _ in }
    ) throws -> URL {
        progressHandler(RuntimeActivationProgress(
            title: "Preparing local files",
            detail: "Creating a temporary install area.",
            completedStep: 1,
            totalSteps: 5
        ))
        let stagingURL = installRoot.appendingPathComponent("staging-\(UUID().uuidString)")
        let extractedURL = stagingURL.appendingPathComponent("extract")
        try fileManager.createDirectory(at: extractedURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingURL) }

        if archiveURL.hasDirectoryPath {
            progressHandler(RuntimeActivationProgress(
                title: "Copying local files",
                detail: "Preparing the runtime directory.",
                completedStep: 2,
                totalSteps: 5
            ))
            try fileManager.copyItem(at: archiveURL, to: extractedURL.appendingPathComponent(archiveURL.lastPathComponent))
        } else if archiveURL.pathExtension.lowercased() == "zip" {
            let archiveSize = formattedFileSize(archiveURL, fileManager: fileManager)
            progressHandler(RuntimeActivationProgress(
                title: "Extracting archive",
                detail: archiveSize.map { "Unpacking \($0) of runtime files." } ?? "Unpacking runtime files.",
                completedStep: 2,
                totalSteps: 5
            ))
            try extractZipArchive(archiveURL, to: extractedURL)
        } else {
            throw RuntimeUpdateError.unsupportedArchive
        }

        progressHandler(RuntimeActivationProgress(
            title: "Validating files",
            detail: "Checking Python runtimes and required components.",
            completedStep: 3,
            totalSteps: 5
        ))
        let runtimeRoot = try normalizedRuntimeRoot(in: extractedURL, fileManager: fileManager)
        try validateExtractedRuntimeTree(runtimeRoot, fileManager: fileManager)
        guard isRuntimeBundleStructurallyValid(runtimeRoot, fileManager: fileManager) else {
            throw RuntimeUpdateError.invalidRuntime
        }

        progressHandler(RuntimeActivationProgress(
            title: "Moving into place",
            detail: "Replacing the active runtime atomically.",
            completedStep: 4,
            totalSteps: 5
        ))
        let currentURL = installRoot.appendingPathComponent("current")
        let nextURL = installRoot.appendingPathComponent("next-\(UUID().uuidString)")
        try fileManager.createDirectory(at: installRoot, withIntermediateDirectories: true)
        try fileManager.moveItem(at: runtimeRoot, to: nextURL)

        let previousURL = installRoot.appendingPathComponent("previous-\(UUID().uuidString)")
        if fileManager.fileExists(atPath: currentURL.path) {
            try fileManager.moveItem(at: currentURL, to: previousURL)
        }
        do {
            try fileManager.moveItem(at: nextURL, to: currentURL)
            try? fileManager.removeItem(at: previousURL)
        } catch {
            if fileManager.fileExists(atPath: previousURL.path) {
                try? fileManager.moveItem(at: previousURL, to: currentURL)
            }
            throw error
        }
        progressHandler(RuntimeActivationProgress(
            title: "Finishing setup",
            detail: "Runtime is ready for local models.",
            completedStep: 5,
            totalSteps: 5
        ))
        return currentURL
    }

    nonisolated static func installRuntimeComponentArchive(
        _ archiveURL: URL,
        component: RuntimeComponent,
        activeRuntimeRoot: URL,
        installRoot: URL,
        fileManager: FileManager = .default,
        progressHandler: @escaping @Sendable (RuntimeActivationProgress) -> Void = { _ in }
    ) throws -> URL {
        guard component == .music else {
            throw RuntimeUpdateError.unsupportedArchive
        }
        guard isRuntimeBundleStructurallyValid(activeRuntimeRoot, fileManager: fileManager) else {
            throw RuntimeUpdateError.invalidRuntime
        }

        progressHandler(RuntimeActivationProgress(
            title: "Preparing local files",
            detail: "Creating a temporary install area.",
            completedStep: 1,
            totalSteps: 5
        ))
        let stagingURL = installRoot.appendingPathComponent("staging-\(UUID().uuidString)")
        let extractedURL = stagingURL.appendingPathComponent("extract")
        try fileManager.createDirectory(at: extractedURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingURL) }

        if archiveURL.hasDirectoryPath {
            progressHandler(RuntimeActivationProgress(
                title: "Copying local files",
                detail: "Preparing the runtime component directory.",
                completedStep: 2,
                totalSteps: 5
            ))
            try fileManager.copyItem(at: archiveURL, to: extractedURL.appendingPathComponent(archiveURL.lastPathComponent))
        } else if archiveURL.pathExtension.lowercased() == "zip" {
            let archiveSize = formattedFileSize(archiveURL, fileManager: fileManager)
            progressHandler(RuntimeActivationProgress(
                title: "Extracting archive",
                detail: archiveSize.map { "Unpacking \($0) of music runtime files." } ?? "Unpacking music runtime files.",
                completedStep: 2,
                totalSteps: 5
            ))
            try extractZipArchive(archiveURL, to: extractedURL)
        } else {
            throw RuntimeUpdateError.unsupportedArchive
        }

        progressHandler(RuntimeActivationProgress(
            title: "Validating files",
            detail: "Checking the music runtime component.",
            completedStep: 3,
            totalSteps: 5
        ))
        let componentRoot = try normalizedRuntimeComponentRoot(
            in: extractedURL,
            component: component,
            baseRuntimeRoot: activeRuntimeRoot,
            fileManager: fileManager
        )
        try validateExtractedRuntimeTree(componentRoot, fileManager: fileManager)

        progressHandler(RuntimeActivationProgress(
            title: "Moving into place",
            detail: "Installing the music runtime component.",
            completedStep: 4,
            totalSteps: 5
        ))
        try replaceRuntimeComponent(
            component,
            from: componentRoot,
            into: activeRuntimeRoot,
            stagingURL: stagingURL,
            fileManager: fileManager
        )
        progressHandler(RuntimeActivationProgress(
            title: "Finishing setup",
            detail: "Music generation runtime is ready.",
            completedStep: 5,
            totalSteps: 5
        ))
        return activeRuntimeRoot
    }

    private nonisolated static func formattedFileSize(_ url: URL, fileManager: FileManager) -> String? {
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size.int64Value)
    }

    private nonisolated static func extractZipArchive(_ archiveURL: URL, to destinationURL: URL) throws {
        try validateZipArchiveEntries(archiveURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RuntimeUpdateError.unsupportedArchive
        }
    }

    private nonisolated static func normalizedRuntimeRoot(
        in extractedURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        if isRuntimeBundleStructurallyValid(extractedURL, fileManager: fileManager) {
            return extractedURL
        }

        let children = try fileManager.contentsOfDirectory(
            at: extractedURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children where isRuntimeBundleStructurallyValid(child, fileManager: fileManager) {
            return child
        }
        throw RuntimeUpdateError.invalidRuntime
    }

    private nonisolated static func normalizedRuntimeComponentRoot(
        in extractedURL: URL,
        component: RuntimeComponent,
        baseRuntimeRoot: URL,
        fileManager: FileManager
    ) throws -> URL {
        if isExtractedRuntimeComponentStructurallyValid(
            component,
            root: extractedURL,
            baseRuntimeRoot: baseRuntimeRoot,
            fileManager: fileManager
        ) {
            return extractedURL
        }

        let children = try fileManager.contentsOfDirectory(
            at: extractedURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children where isExtractedRuntimeComponentStructurallyValid(
            component,
            root: child,
            baseRuntimeRoot: baseRuntimeRoot,
            fileManager: fileManager
        ) {
            return child
        }
        throw RuntimeUpdateError.invalidRuntime
    }

    private nonisolated static func isExtractedRuntimeComponentStructurallyValid(
        _ component: RuntimeComponent,
        root: URL,
        baseRuntimeRoot: URL,
        fileManager: FileManager
    ) -> Bool {
        switch component {
        case .base:
            return isRuntimeBundleStructurallyValid(root, fileManager: fileManager)
        case .music:
            guard runtimeManifest(at: root, component: .music)?.component == .music else {
                return false
            }
            let requiredFiles = [
                "acestep-venv/bin/python",
                "acestep_download_helper.py",
                RuntimeComponent.music.manifestFilename,
            ]
            guard requiredFiles.allSatisfy({ relativePath in
                runtimeTreeItemExists(root.appendingPathComponent(relativePath), fileManager: fileManager)
            }) else {
                return false
            }
            let python = root.appendingPathComponent("acestep-venv/bin/python")
            if fileManager.isExecutableFile(atPath: python.path) {
                return true
            }
            guard (try? fileManager.destinationOfSymbolicLink(atPath: python.path)) != nil else {
                return false
            }
            return fileManager.fileExists(
                atPath: baseRuntimeRoot.appendingPathComponent("python/Frameworks/Versions/3.12").path
            )
        }
    }

    private nonisolated static func replaceRuntimeComponent(
        _ component: RuntimeComponent,
        from componentRoot: URL,
        into activeRuntimeRoot: URL,
        stagingURL: URL,
        fileManager: FileManager
    ) throws {
        let relativePaths: [String]
        switch component {
        case .base:
            throw RuntimeUpdateError.unsupportedArchive
        case .music:
            relativePaths = [
                "acestep-venv",
                "acestep_download_helper.py",
                RuntimeComponent.music.manifestFilename,
            ]
        }

        let backupURL = stagingURL.appendingPathComponent("backup-\(component.rawValue)-\(UUID().uuidString)")
        let nextURL = stagingURL.appendingPathComponent("next-\(component.rawValue)-\(UUID().uuidString)")
        try fileManager.createDirectory(at: backupURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nextURL, withIntermediateDirectories: true)

        for relativePath in relativePaths {
            let source = componentRoot.appendingPathComponent(relativePath)
            let prepared = nextURL.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: prepared.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: prepared)
        }

        var movedToBackup: [String] = []
        do {
            for relativePath in relativePaths {
                let target = activeRuntimeRoot.appendingPathComponent(relativePath)
                if fileManager.fileExists(atPath: target.path) {
                    let backup = backupURL.appendingPathComponent(relativePath)
                    try fileManager.createDirectory(
                        at: backup.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.moveItem(at: target, to: backup)
                    movedToBackup.append(relativePath)
                }
            }

            for relativePath in relativePaths {
                let prepared = nextURL.appendingPathComponent(relativePath)
                let target = activeRuntimeRoot.appendingPathComponent(relativePath)
                try fileManager.moveItem(at: prepared, to: target)
            }
        } catch {
            for relativePath in relativePaths {
                let target = activeRuntimeRoot.appendingPathComponent(relativePath)
                if fileManager.fileExists(atPath: target.path) {
                    try? fileManager.removeItem(at: target)
                }
            }
            for relativePath in movedToBackup {
                let backup = backupURL.appendingPathComponent(relativePath)
                let target = activeRuntimeRoot.appendingPathComponent(relativePath)
                if fileManager.fileExists(atPath: backup.path) {
                    try? fileManager.moveItem(at: backup, to: target)
                }
            }
            throw error
        }

        guard isRuntimeComponentStructurallyValid(component, at: activeRuntimeRoot, fileManager: fileManager) else {
            for relativePath in relativePaths {
                let target = activeRuntimeRoot.appendingPathComponent(relativePath)
                if fileManager.fileExists(atPath: target.path) {
                    try? fileManager.removeItem(at: target)
                }
            }
            for relativePath in movedToBackup {
                let backup = backupURL.appendingPathComponent(relativePath)
                let target = activeRuntimeRoot.appendingPathComponent(relativePath)
                if fileManager.fileExists(atPath: backup.path) {
                    try? fileManager.moveItem(at: backup, to: target)
                }
            }
            throw RuntimeUpdateError.invalidRuntime
        }
    }

    private nonisolated static func prepareInstalledBaseRuntimeIfNeeded(
        currentURL: URL,
        fileManager: FileManager
    ) throws {
        if isRuntimeBundleStructurallyValid(currentURL, fileManager: fileManager) {
            return
        }

        let activeBase = activeRuntimeBundleURL(fileManager: fileManager)
        guard isRuntimeBundleStructurallyValid(activeBase, fileManager: fileManager) else {
            throw RuntimeUpdateError.invalidRuntime
        }
        try fileManager.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let nextURL = currentURL.deletingLastPathComponent().appendingPathComponent("base-copy-\(UUID().uuidString)")
        try fileManager.copyItem(at: activeBase, to: nextURL)
        if fileManager.fileExists(atPath: currentURL.path) {
            try fileManager.removeItem(at: currentURL)
        }
        try fileManager.moveItem(at: nextURL, to: currentURL)
    }

    private nonisolated static func validateZipArchiveEntries(_ archiveURL: URL) throws {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", archiveURL.path]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw RuntimeUpdateError.unsupportedArchive
        }

        let stdoutReader = PipeDataReader(handle: outputPipe.fileHandleForReading)
        let stderrReader = PipeDataReader(handle: errorPipe.fileHandleForReading)
        let group = DispatchGroup()
        stdoutReader.start(on: DispatchQueue(label: "com.localstudio.mlxtra.zipinfo.stdout", qos: .utility), group: group)
        stderrReader.start(on: DispatchQueue(label: "com.localstudio.mlxtra.zipinfo.stderr", qos: .utility), group: group)
        process.waitUntilExit()
        group.wait()

        guard process.terminationStatus == 0 else {
            throw RuntimeUpdateError.unsupportedArchive
        }

        let output = String(data: stdoutReader.collectedData(), encoding: .utf8) ?? ""
        for rawEntry in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard isSafeArchiveEntryPath(String(rawEntry)) else {
                throw RuntimeUpdateError.invalidRuntime
            }
        }
    }

    private nonisolated static func isSafeArchiveEntryPath(_ entry: String) -> Bool {
        guard !entry.isEmpty, !entry.hasPrefix("/") else {
            return false
        }
        let components = entry.split(separator: "/", omittingEmptySubsequences: true)
        return !components.contains("..")
    }

    private nonisolated static func validateExtractedRuntimeTree(
        _ rootURL: URL,
        fileManager: FileManager
    ) throws {
        let standardizedRoot = rootURL.standardizedFileURL
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            throw RuntimeUpdateError.invalidRuntime
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink == true else {
                continue
            }
            let target = try symlinkTargetURL(for: url, fileManager: fileManager)
            let standardizedTarget = target.standardizedFileURL
            let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL
            guard isURL(standardizedTarget, containedIn: standardizedRoot)
                    || isURL(resolvedTarget, containedIn: resolvedRoot) else {
                throw RuntimeUpdateError.invalidRuntime
            }
        }
    }

    private nonisolated static func isURL(_ candidate: URL, containedIn root: URL) -> Bool {
        let candidatePath = normalizedContainmentPath(candidate.path)
        let rootPath = normalizedContainmentPath(root.path)
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private nonisolated static func normalizedContainmentPath(_ path: String) -> String {
        if path.hasPrefix("/private/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    private nonisolated static func runtimeTreeItemExists(_ url: URL, fileManager: FileManager) -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            return true
        }
        return (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private nonisolated static func symlinkTargetURL(for url: URL, fileManager: FileManager) throws -> URL {
        let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination)
        }
        let targetPath = (url.deletingLastPathComponent().path as NSString)
            .appendingPathComponent(destination)
        return URL(fileURLWithPath: targetPath).standardizedFileURL
    }
}
