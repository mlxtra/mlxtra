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

    private func waitForGeneratedAttachment(
        identifier: String,
        fallbackStaticText: String
    ) -> String {
        let attachment = app.descendants(matching: .any)[identifier]
        if attachment.waitForExistence(timeout: 10) {
            guard let path = attachment.value as? String, !path.isEmpty else {
                XCTFail("Generated attachment \(identifier) did not expose a file path")
                return ""
            }
            return path
        }

        XCTAssertTrue(
            app.staticTexts[fallbackStaticText].waitForExistence(timeout: 10),
            "Missing generated attachment \(identifier)"
        )
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
