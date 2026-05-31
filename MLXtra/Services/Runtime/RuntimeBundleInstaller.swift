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
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
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
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard isURL(resolved, containedIn: root) else {
                throw RuntimeUpdateError.invalidRuntime
            }
        }
    }

    private nonisolated static func isURL(_ candidate: URL, containedIn root: URL) -> Bool {
        let candidatePath = candidate.path
        let rootPath = root.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
