import XCTest
@testable import MLXtra

final class NativeModelFileVerifierTests: XCTestCase {
    func testVerifyFileRejectsMissingAndSizeMismatchedFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("model.safetensors")
        let verifier = NativeModelFileVerifier()

        XCTAssertThrowsError(
            try verifier.verifyFile(
                fileURL,
                manifestFile: HuggingFaceManifestFile(path: "model.safetensors", size: 2, sha256: nil)
            )
        ) { error in
            XCTAssertEqual(error as? NativeModelDownloadError, .missingDownloadedFile("model.safetensors"))
        }

        try Data([1]).write(to: fileURL)

        XCTAssertThrowsError(
            try verifier.verifyFile(
                fileURL,
                manifestFile: HuggingFaceManifestFile(path: "model.safetensors", size: 2, sha256: nil)
            )
        ) { error in
            XCTAssertEqual(
                error as? NativeModelDownloadError,
                .sizeMismatch("model.safetensors", expected: 2, actual: 1)
            )
        }
    }

    func testVerifyFileRejectsChecksumMismatchByDefault() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("model.safetensors")
        try Data([1, 2, 3, 4]).write(to: fileURL)

        XCTAssertThrowsError(
            try NativeModelFileVerifier().verifyFile(
                fileURL,
                manifestFile: HuggingFaceManifestFile(
                    path: "model.safetensors",
                    size: 4,
                    sha256: String(repeating: "0", count: 64)
                )
            )
        ) { error in
            XCTAssertEqual(error as? NativeModelDownloadError, .checksumMismatch("model.safetensors"))
        }
    }

    func testSkipLargeFileHashVerificationPreservesSmallFileVerification() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let smallURL = root.appendingPathComponent("small.safetensors")
        let largeURL = root.appendingPathComponent("large.safetensors")
        let badSHA = String(repeating: "0", count: 64)
        let verifier = NativeModelFileVerifier(
            skipLargeFileHashVerification: true,
            hashVerifyMaxBytes: 2
        )

        try Data([1, 2]).write(to: smallURL)
        try Data([1, 2, 3]).write(to: largeURL)

        XCTAssertThrowsError(
            try verifier.verifyFile(
                smallURL,
                manifestFile: HuggingFaceManifestFile(path: "small.safetensors", size: 2, sha256: badSHA)
            )
        ) { error in
            XCTAssertEqual(error as? NativeModelDownloadError, .checksumMismatch("small.safetensors"))
        }

        XCTAssertNoThrow(
            try verifier.verifyFile(
                largeURL,
                manifestFile: HuggingFaceManifestFile(path: "large.safetensors", size: 3, sha256: badSHA)
            )
        )
    }

    func testExistingVerifiedBytesAndAggregateSizeUseOnlyCompleteFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2]).write(to: root.appendingPathComponent("complete.bin"))
        try Data([1]).write(to: root.appendingPathComponent("short.bin"))

        let files = [
            HuggingFaceManifestFile(path: "complete.bin", size: 2, sha256: nil),
            HuggingFaceManifestFile(path: "short.bin", size: 2, sha256: nil),
            HuggingFaceManifestFile(path: "missing.bin", size: 3, sha256: nil)
        ]
        let verifier = NativeModelFileVerifier()

        XCTAssertEqual(verifier.aggregateSize(for: files), 7)
        XCTAssertEqual(verifier.existingVerifiedBytes(for: files, destinationRoot: root), 2)
        XCTAssertNil(
            verifier.aggregateSize(
                for: [HuggingFaceManifestFile(path: "unknown.bin", size: nil, sha256: nil)]
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXtraTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
