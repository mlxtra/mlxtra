import XCTest

final class MLXtraDownloadStatesUITests: XCTestCase {
    private var app: XCUIApplication!
    private static let screenshotRunID: String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: Date()))-\(ProcessInfo.processInfo.processIdentifier)"
    }()
    private static let screenshotDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MLXtraDownloadStateScreenshots", isDirectory: true)
        .appendingPathComponent(screenshotRunID, isDirectory: true)
    private static var didPrintScreenshotDirectory = false

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        try FileManager.default.createDirectory(
            at: Self.screenshotDirectory,
            withIntermediateDirectories: true
        )
        if !Self.didPrintScreenshotDirectory {
            print("Download-state screenshot directory: \(Self.screenshotDirectory.path)")
            Self.didPrintScreenshotDirectory = true
        }

        app = XCUIApplication()
        app.launchEnvironment["MLXTRA_UI_TEST_MODE"] = "1"
        app.launchEnvironment["MLXTRA_UI_TEST_DOWNLOAD_STATES"] = "1"
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

    func testModelSettingsRenderAllDownloadStates() throws {
        openSettings()

        try saveScreenshot(named: "Model download states - Chat", fileName: "settings-download-states-chat.png")
        XCTAssertTrue(app.staticTexts["Ready"].exists)
        XCTAssertTrue(app.buttons["Download"].exists)
        XCTAssertTrue(app.staticTexts["Downloading"].exists || app.staticTexts["50%"].exists)

        selectMode("Images")
        try saveScreenshot(named: "Model download states - Images", fileName: "settings-download-states-images.png")
        XCTAssertTrue(app.staticTexts["Paused"].exists)

        selectMode("Voice")
        try saveScreenshot(named: "Model download states - Voice", fileName: "settings-download-states-voice.png")
        XCTAssertTrue(app.staticTexts["Needs repair"].exists || app.buttons["Repair"].exists)

        selectMode("Music")
        try saveScreenshot(named: "Model download states - Music", fileName: "settings-download-states-music.png")
        XCTAssertTrue(app.staticTexts["Failed"].exists || app.buttons["Retry"].exists)
    }

    private func openSettings() {
        app.typeKey(",", modifierFlags: [.command])

        let settingsWindow = app.descendants(matching: .any)["settings.window"]
        if settingsWindow.waitForExistence(timeout: 5) {
            return
        }

        let menuItem = app.menuBars.menuBarItems["MLXtra"].menus.menuItems["Settings..."]
        if menuItem.exists {
            menuItem.click()
        }

        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5), "Settings window did not open")
    }

    private func selectMode(_ title: String) {
        let radioButton = app.radioButtons[title]
        if radioButton.waitForExistence(timeout: 2) {
            radioButton.click()
            return
        }

        let button = app.buttons[title]
        if button.waitForExistence(timeout: 2) {
            button.click()
            return
        }

        let label = app.staticTexts[title]
        XCTAssertTrue(label.waitForExistence(timeout: 2), "Missing \(title) mode")
        label.click()
    }

    private func saveScreenshot(named name: String, fileName: String) throws {
        let appScreenshot = app.screenshot()
        let screenshot = XCTAttachment(screenshot: appScreenshot)
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let fileURL = Self.screenshotDirectory.appendingPathComponent(fileName)
        try appScreenshot.pngRepresentation.write(to: fileURL, options: [.atomic])
        print("Saved download-state screenshot: \(fileURL.path)")
    }
}
