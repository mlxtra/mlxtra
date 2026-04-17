import XCTest
@testable import MLXHub

final class ModelDownloadManagerTests: XCTestCase {

    // MARK: - DownloadState Tests

    func testDownloadStateEquatable() {
        XCTAssertEqual(ModelDownloadManager.DownloadState.notDownloaded, ModelDownloadManager.DownloadState.notDownloaded)
        XCTAssertEqual(ModelDownloadManager.DownloadState.downloading(nil), ModelDownloadManager.DownloadState.downloading(nil))
        XCTAssertEqual(ModelDownloadManager.DownloadState.downloaded, ModelDownloadManager.DownloadState.downloaded)
        XCTAssertEqual(ModelDownloadManager.DownloadState.failed("error"), ModelDownloadManager.DownloadState.failed("error"))
        XCTAssertNotEqual(ModelDownloadManager.DownloadState.notDownloaded, ModelDownloadManager.DownloadState.downloaded)
        XCTAssertNotEqual(ModelDownloadManager.DownloadState.failed("error1"), ModelDownloadManager.DownloadState.failed("error2"))
    }

    func testDownloadStateIsDownloading() {
        XCTAssertFalse(ModelDownloadManager.DownloadState.notDownloaded.isDownloading)
        XCTAssertTrue(ModelDownloadManager.DownloadState.downloading(nil).isDownloading)
        XCTAssertFalse(ModelDownloadManager.DownloadState.downloaded.isDownloading)
        XCTAssertFalse(ModelDownloadManager.DownloadState.failed("error").isDownloading)
    }

    func testDownloadProgressFormatting() {
        let progress = ModelDownloadManager.DownloadProgress(
            status: "downloading",
            description: "Downloading",
            downloadedBytes: 1_048_576,
            totalBytes: 2_097_152,
            percent: 50.0
        )

        XCTAssertEqual(progress.displayText, "50%")
        XCTAssertEqual(progress.fractionCompleted, 0.5)
        XCTAssertNotNil(progress.detailText)
    }

    func testDownloadErrorTrackerCanClearStaleErrorForRetry() {
        let tracker = DownloadErrorTracker()
        let modelId = "org/model"

        tracker.setErrorReceived(for: modelId)
        XCTAssertTrue(tracker.errorWasReceived(for: modelId))

        tracker.clearErrorReceived(for: modelId)
        XCTAssertFalse(tracker.errorWasReceived(for: modelId))
    }

    func testAceStepDownloadHelperUsageErrorUsesTypedEvent() throws {
        let helperPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("MLXHub/Resources/runtime/macos-arm64/acestep_download_helper.py")

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helperPath.path]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let firstLine = try XCTUnwrap(output.split(separator: "\n").first)
        let data = Data(firstLine.utf8)
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertEqual(event["type"] as? String, "download.error")
        XCTAssertEqual(event["message"] as? String, "Usage: acestep_download_helper.py <repo_id> <local_dir>")
    }

    // MARK: - ModelDownloadError Tests

    func testModelDownloadErrorLocalizedDescription() {
        XCTAssertEqual(
            ModelDownloadError.downloadFailed("Download failed").errorDescription,
            "Download failed"
        )
        XCTAssertEqual(
            ModelDownloadError.downloadFailed("").errorDescription,
            ""
        )
    }
}
