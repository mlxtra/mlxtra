import XCTest
@testable import MLXHub

final class ModelDownloadManagerTests: XCTestCase {

    // MARK: - DownloadState Tests

    func testDownloadStateEquatable() {
        XCTAssertEqual(ModelDownloadManager.DownloadState.notDownloaded, ModelDownloadManager.DownloadState.notDownloaded)
        XCTAssertEqual(ModelDownloadManager.DownloadState.downloading, ModelDownloadManager.DownloadState.downloading)
        XCTAssertEqual(ModelDownloadManager.DownloadState.downloaded, ModelDownloadManager.DownloadState.downloaded)
        XCTAssertEqual(ModelDownloadManager.DownloadState.failed("error"), ModelDownloadManager.DownloadState.failed("error"))
        XCTAssertNotEqual(ModelDownloadManager.DownloadState.notDownloaded, ModelDownloadManager.DownloadState.downloaded)
        XCTAssertNotEqual(ModelDownloadManager.DownloadState.failed("error1"), ModelDownloadManager.DownloadState.failed("error2"))
    }

    func testDownloadStateIsDownloading() {
        XCTAssertFalse(ModelDownloadManager.DownloadState.notDownloaded.isDownloading)
        XCTAssertTrue(ModelDownloadManager.DownloadState.downloading.isDownloading)
        XCTAssertFalse(ModelDownloadManager.DownloadState.downloaded.isDownloading)
        XCTAssertFalse(ModelDownloadManager.DownloadState.failed("error").isDownloading)
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