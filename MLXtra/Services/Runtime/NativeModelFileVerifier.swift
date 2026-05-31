import Foundation

struct NativeModelFileVerifier {
    let fileManager: FileManager
    let skipLargeFileHashVerification: Bool
    let hashVerifyMaxBytes: Int64

    init(
        fileManager: FileManager = .default,
        skipLargeFileHashVerification: Bool = false,
        hashVerifyMaxBytes: Int64 = 64 * 1024 * 1024
    ) {
        self.fileManager = fileManager
        self.skipLargeFileHashVerification = skipLargeFileHashVerification
        self.hashVerifyMaxBytes = hashVerifyMaxBytes
    }

    func verifyManifest(_ files: [HuggingFaceManifestFile], destinationRoot: URL) throws {
        for file in files {
            try verifyFile(destinationRoot.appendingPathComponent(file.path), manifestFile: file)
        }
    }

    func verifyFile(_ fileURL: URL, manifestFile: HuggingFaceManifestFile) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw NativeModelDownloadError.missingDownloadedFile(manifestFile.path)
        }

        if let expectedSize = manifestFile.size {
            let actualSize = fileSize(fileURL) ?? -1
            guard actualSize == expectedSize else {
                throw NativeModelDownloadError.sizeMismatch(
                    manifestFile.path,
                    expected: expectedSize,
                    actual: actualSize
                )
            }
        }

        guard let expectedSHA256 = manifestFile.sha256,
              shouldVerifyHash(size: manifestFile.size) else {
            return
        }

        let actualSHA256 = try SHA256Checksum.hexDigest(for: fileURL)
        guard actualSHA256.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw NativeModelDownloadError.checksumMismatch(manifestFile.path)
        }
    }

    func isFileComplete(_ fileURL: URL, manifestFile: HuggingFaceManifestFile) -> Bool {
        do {
            try verifyFile(fileURL, manifestFile: manifestFile)
            return true
        } catch {
            return false
        }
    }

    func existingVerifiedBytes(for files: [HuggingFaceManifestFile], destinationRoot: URL) -> Int64 {
        files.reduce(Int64(0)) { total, file in
            let destinationURL = destinationRoot.appendingPathComponent(file.path)
            guard isFileComplete(destinationURL, manifestFile: file) else {
                return total
            }
            return total + (file.size ?? fileSize(destinationURL) ?? 0)
        }
    }

    func aggregateSize(for files: [HuggingFaceManifestFile]) -> Int64? {
        var total: Int64 = 0
        for file in files {
            guard let size = file.size else { return nil }
            total += size
        }
        return total
    }

    func fileSize(_ url: URL) -> Int64? {
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private func shouldVerifyHash(size: Int64?) -> Bool {
        !skipLargeFileHashVerification || (size ?? 0) <= hashVerifyMaxBytes
    }
}
