import XCTest

final class MLXHubDownloadStatesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchEnvironment["MLXHUB_UI_TEST_MODE"] = "1"
        app.launchEnvironment["MLXHUB_UI_TEST_DOWNLOAD_STATES"] = "1"
        app.launchArguments.append(contentsOf: [
            "-ApplePersistenceIgnoreState",
            "YES",
        ])
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    override func tearDown() {
        app.terminate()
        app = nil
        super.tearDown()
    }

    func testModelSettingsRenderAllDownloadStates() {
        openSettings()

        assertStateExists("settings.modelState.ready", label: "ready")
        assertStateExists("settings.modelState.missing", label: "missing")
        assertStateExists("settings.modelState.downloading", label: "downloading")
        assertStateExists("settings.modelState.paused", label: "paused")
        assertStateExists("settings.modelState.repair", label: "repair")
        assertStateExists("settings.modelState.failed", label: "failed")

        XCTAssertTrue(app.staticTexts["Ready"].exists)
        XCTAssertTrue(app.buttons["Download"].exists)
        XCTAssertTrue(app.staticTexts["Downloading"].exists || app.staticTexts["50%"].exists)
        XCTAssertTrue(app.staticTexts["Paused"].exists)
        XCTAssertTrue(app.buttons["Repair"].exists)
        XCTAssertTrue(app.buttons["Retry"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Model download states"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func openSettings() {
        app.typeKey(",", modifierFlags: [.command])

        let settingsWindow = app.descendants(matching: .any)["settings.window"]
        if settingsWindow.waitForExistence(timeout: 5) {
            return
        }

        let menuItem = app.menuBars.menuBarItems["MLXHub"].menus.menuItems["Settings..."]
        if menuItem.exists {
            menuItem.click()
        }

        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5), "Settings window did not open")
    }

    private func assertStateExists(_ identifier: String, label: String) {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing \(label) download state")
    }
}
