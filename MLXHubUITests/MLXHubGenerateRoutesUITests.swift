import AppKit
import AVFoundation
import XCTest

final class MLXHubGenerateRoutesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchEnvironment["MLXHUB_UI_TEST_MODE"] = "1"
        app.launchArguments.append(contentsOf: [
            "-ApplePersistenceIgnoreState",
            "YES",
        ])
        app.launch()
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    override func tearDown() {
        app.terminate()
        app = nil
        super.tearDown()
    }

    func testChatGenerateRouteReturnsAssistantMessage() {
        selectWelcomeTool("Chat")
        enterPrompt("Answer with a short deterministic sentence.")
        clickGenerate()

        XCTAssertTrue(
            app.staticTexts["UI test chat response"].waitForExistence(timeout: 10)
        )
    }

    func testResearchGenerateRouteReturnsAssistantMessage() {
        selectWelcomeTool("Research")
        enterPrompt("Research a deterministic UI test topic.")
        clickGenerate()

        XCTAssertTrue(
            app.staticTexts["UI test chat response"].waitForExistence(timeout: 10)
        )
    }

    func testImageGenerateRouteCreatesImageAttachment() {
        selectWelcomeTool("Image")
        enterPrompt("Create a simple gradient square.")
        clickGenerate()

        let path = waitForGeneratedAttachment(
            identifier: "generated.image",
            fallbackStaticText: "Generated image"
        )
        validatePNG(at: path, expectedWidth: 64, expectedHeight: 64)
    }

    func testSpeechGenerateRouteCreatesAudioAttachment() {
        selectWelcomeTool("Speech")
        enterPrompt("Say this generated speech test sentence.")
        clickGenerate()

        let path = waitForGeneratedAttachment(
            identifier: "generated.audio.speech",
            fallbackStaticText: "Generated speech"
        )
        validateAudio(at: path, expectedSampleRate: 24_000, minimumDuration: 0.95)
    }

    func testMusicGenerateRouteCreatesAudioAttachment() {
        selectWelcomeTool("Music")
        enterPrompt("Moody cyberpunk instrumental music.")
        clickGenerate()

        let path = waitForGeneratedAttachment(
            identifier: "generated.audio.music",
            fallbackStaticText: "Generated music"
        )
        validateAudio(at: path, expectedSampleRate: 48_000, minimumDuration: 0.95)
    }

    func testCommandNCreatesEmptyChat() {
        selectWelcomeTool("Chat")
        enterPrompt("Answer with a short deterministic sentence.")
        clickGenerate()

        XCTAssertTrue(
            app.staticTexts["UI test chat response"].waitForExistence(timeout: 10),
            "Expected an existing transcript before invoking New Chat"
        )
        XCTAssertGreaterThan(
            messageCount(identifier: "message.assistant"),
            0,
            "Expected an assistant transcript message before invoking New Chat"
        )

        app.typeKey("n", modifierFlags: [.command])

        XCTAssertTrue(
            app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5),
            "Cmd+N should switch to a new empty chat"
        )
        XCTAssertEqual(
            messageCount(identifier: "message.assistant"),
            0,
            "New chat should not show the previous transcript"
        )
    }

    func testCommandPeriodStopsActiveGeneration() {
        selectWelcomeTool("Chat")
        enterPrompt("UI test streaming scroll response.")
        clickGenerate()

        let primaryAction = app.buttons["composer.primaryAction"]
        XCTAssertTrue(
            waitForPrimaryActionLabel(containing: "stop", timeout: 5),
            "Streaming generation should expose the stop action before Cmd+."
        )

        app.typeKey(".", modifierFlags: [.command])

        XCTAssertTrue(
            waitForPrimaryActionLabelNotContaining("stop", timeout: 5),
            "Cmd+. should stop the active generation"
        )
        XCTAssertFalse(
            app.staticTexts["Streaming scroll response ends."].waitForExistence(timeout: 1),
            "Stopped streaming response should not finish after Cmd+."
        )
        XCTAssertTrue(primaryAction.exists)
    }

    func testOptionCommandFFocusesComposer() {
        selectWelcomeTool("Chat")

        let input = composerInput()
        XCTAssertTrue(input.waitForExistence(timeout: 5), "Missing composer input")

        app.typeKey("f", modifierFlags: [.command, .option])
        app.typeText("Focused by command")

        XCTAssertTrue(
            waitForComposerValue(containing: "Focused by command", timeout: 5),
            "Option+Cmd+F should focus the composer so keyboard input lands there"
        )
    }

    private func selectWelcomeTool(_ toolId: String) {
        let button = app.buttons
            .matching(identifier: "welcome.tool.\(toolId)")
            .element(boundBy: 0)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing \(toolId) chip")
        button.click()
    }

    private func enterPrompt(_ text: String) {
        let input = composerInput()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        input.click()
        app.typeKey("v", modifierFlags: [.command])
    }

    private func composerInput() -> XCUIElement {
        let textView = app.textViews["composer.input"]
        if textView.waitForExistence(timeout: 5) {
            return textView
        }

        let anyElement = app.descendants(matching: .any)["composer.input"]
        XCTAssertTrue(anyElement.waitForExistence(timeout: 5))
        return anyElement
    }

    private func clickGenerate() {
        let button = app.buttons["composer.primaryAction"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isEnabled)
        button.click()
    }

    private func waitForComposerValue(containing text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let inputValue = String(describing: composerInput().value ?? "")
            if inputValue.contains(text) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return false
    }

    private func messageCount(identifier: String) -> Int {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .allElementsBoundByIndex
            .filter(\.exists)
            .count
    }

    private func waitForPrimaryActionLabel(
        containing text: String,
        timeout: TimeInterval
    ) -> Bool {
        waitForPrimaryActionLabel(timeout: timeout) { label in
            label.localizedCaseInsensitiveContains(text)
        }
    }

    private func waitForPrimaryActionLabelNotContaining(
        _ text: String,
        timeout: TimeInterval
    ) -> Bool {
        waitForPrimaryActionLabel(timeout: timeout) { label in
            !label.localizedCaseInsensitiveContains(text)
        }
    }

    private func waitForPrimaryActionLabel(
        timeout: TimeInterval,
        matches predicate: (String) -> Bool
    ) -> Bool {
        let button = app.buttons["composer.primaryAction"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate(button.label) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return false
    }

    private func waitForGeneratedAttachment(
        identifier: String,
        fallbackStaticText: String
    ) -> String {
        let query = app.descendants(matching: .any)
            .matching(identifier: identifier)
        let deadline = Date().addingTimeInterval(10)

        repeat {
            let matches = query.allElementsBoundByIndex.filter(\.exists)
            if let path = matches
                .compactMap({ $0.value as? String })
                .first(where: { !$0.isEmpty }) {
                return path
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        XCTAssertTrue(app.staticTexts[fallbackStaticText].exists, "Missing generated attachment \(identifier)")
        XCTFail("Generated attachment \(identifier) did not expose a file path")
        return ""
    }

    private func validatePNG(at path: String, expectedWidth: Int, expectedHeight: Int) {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let imageRep = NSBitmapImageRep(data: data) else {
            XCTFail("Generated PNG is not readable at \(path)")
            return
        }

        XCTAssertEqual(imageRep.pixelsWide, expectedWidth)
        XCTAssertEqual(imageRep.pixelsHigh, expectedHeight)
    }

    private func validateAudio(at path: String, expectedSampleRate: Double, minimumDuration: Double) {
        let url = URL(fileURLWithPath: path)

        do {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.fileFormat.sampleRate
            let duration = Double(file.length) / sampleRate

            XCTAssertEqual(sampleRate, expectedSampleRate, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(duration, minimumDuration)
        } catch {
            XCTFail("Generated audio is not readable at \(path): \(error)")
        }
    }
}
