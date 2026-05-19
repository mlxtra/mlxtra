import XCTest
@testable import MLXtra

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    func testUpdateControllerStaysDisabledWithoutReleaseKey() {
        let controller = AppUpdateController(startingUpdater: false)

        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertEqual(controller.status, .unavailable)
    }

    func testUpdateConfigurationRequiresHTTPSFeedAndPublicKey() {
        XCTAssertTrue(
            AppUpdateController.isUsableUpdateConfiguration(
                feedURL: "https://github.com/mlxtra/mlxtra/releases/download/appcast-stable/appcast.xml",
                publicKey: "valid-public-key"
            )
        )

        XCTAssertFalse(
            AppUpdateController.isUsableUpdateConfiguration(
                feedURL: "http://github.com/mlxtra/mlxtra/releases/download/appcast-stable/appcast.xml",
                publicKey: "valid-public-key"
            )
        )
        XCTAssertFalse(
            AppUpdateController.isUsableUpdateConfiguration(
                feedURL: "$(MLXTRA_SPARKLE_FEED_URL)",
                publicKey: "valid-public-key"
            )
        )
        XCTAssertFalse(
            AppUpdateController.isUsableUpdateConfiguration(
                feedURL: "https://github.com/mlxtra/mlxtra/releases/download/appcast-stable/appcast.xml",
                publicKey: ""
            )
        )
        XCTAssertFalse(
            AppUpdateController.isUsableUpdateConfiguration(
                feedURL: "https://github.com/mlxtra/mlxtra/releases/download/appcast-stable/appcast.xml",
                publicKey: "$(MLXTRA_SPARKLE_PUBLIC_ED_KEY)"
            )
        )
    }
}
