import AppKit
import XCTest

final class MLXHubChatLayoutUITests: XCTestCase {
    private var app: XCUIApplication!
    private static let screenshotRunID: String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: Date()))-\(ProcessInfo.processInfo.processIdentifier)"
    }()
    private static let runScreenshotDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MLXHubChatLayoutScreenshots", isDirectory: true)
        .appendingPathComponent(screenshotRunID, isDirectory: true)
    private static var didPrintScreenshotDirectory = false

    private var screenshotDirectory: URL {
        Self.runScreenshotDirectory
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        try FileManager.default.createDirectory(
            at: screenshotDirectory,
            withIntermediateDirectories: true
        )
        if !Self.didPrintScreenshotDirectory {
            print("UI screenshot run directory: \(screenshotDirectory.path)")
            Self.didPrintScreenshotDirectory = true
        }

        app = XCUIApplication()
        app.launchEnvironment["MLXHUB_UI_TEST_MODE"] = "1"
        if name.contains("testTranscriptLiftsAboveExpandedMusicComposer") {
            app.launchEnvironment["MLXHUB_UI_TEST_WINDOW_WIDTH"] = "980"
            app.launchEnvironment["MLXHUB_UI_TEST_WINDOW_HEIGHT"] = "640"
        } else if name.contains("testNarrowWindowMessageAndComposerWidths") {
            app.launchEnvironment["MLXHUB_UI_TEST_WINDOW_WIDTH"] = "860"
            app.launchEnvironment["MLXHUB_UI_TEST_WINDOW_HEIGHT"] = "680"
        } else if name.contains("testFullWidthPlainMessageRail") {
            app.launchEnvironment["MLXHUB_UI_TEST_WINDOW_WIDTH"] = "1460"
            app.launchEnvironment["MLXHUB_UI_TEST_WINDOW_HEIGHT"] = "900"
        }
        if name.contains("testComposerModelLoadingIndicatorDoesNotResizeComposer") {
            app.launchEnvironment["MLXHUB_UI_TEST_FORCE_MODEL_LOADING_INDICATOR"] = "1"
        }
        if name.contains("testComposerModelPickerShowsReadyModelsOnly") {
            app.launchEnvironment["MLXHUB_UI_TEST_DOWNLOAD_STATES"] = "1"
        }
        if name.contains("testCollapsedSidebarShowsToolbarNewChatButton") {
            app.launchEnvironment["MLXHUB_UI_TEST_HIDE_SIDEBAR"] = "1"
        }
        app.launchArguments.append(contentsOf: [
            "-ApplePersistenceIgnoreState",
            "YES",
        ])
        app.launch()
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    func testMainChatWindowLayoutSnapshots() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5))
        assertSidebarHeaderPlacesNewChatAboveSearch()
        XCTAssertFalse(app.buttons["toolbar.newChat"].exists, "Toolbar New chat should not duplicate the visible sidebar control")
        assertInitialDraftChatIsUntitled()
        assertWelcomePromptChipsLookClickable()
        assertComposerIsBoundedBottomAccessory()
        assertComposerModelControlReplacesToolbarControls()
        try captureScreenshot(named: "01-empty-chat")

        selectWelcomeTool("Chat")
        let response = sendPrompt(
            "Answer with a short deterministic sentence.",
            expecting: "UI test chat response"
        )
        assertComposerIsBoundedBottomAccessory()
        assertResponseClearsComposer(response)
        assertAssistantContentMatchesComposerRail()
        assertLastUserBubbleEndsOnComposerRail()
        assertSidebarSelectionAlignsWithSearchRail()
        assertSidebarHoverActionUsesBalancedInsets()
        assertPerformanceMetricsAreHoverOnly()
        assertHoverAccessoriesDoNotMoveComposer(
            response,
            expectedCopiedText: "UI test chat response"
        )
        assertUserHoverAccessoriesSitUnderSentMessage(
            expectedCopiedText: "Answer with a short deterministic sentence."
        )
        assertLocalEngineStatusIsNotLoading()
        try captureScreenshot(named: "02-chat-response")
    }

    func testCollapsedSidebarShowsToolbarNewChatButtonSnapshot() throws {
        let toolbarNewChat = app.buttons["toolbar.newChat"]
        XCTAssertTrue(toolbarNewChat.waitForExistence(timeout: 5), "Missing toolbar New chat button when sidebar is hidden")
        XCTAssertTrue(toolbarNewChat.isHittable, "Toolbar New chat should be directly usable when sidebar is hidden")
        XCTAssertFalse(app.buttons["sidebar.newChat"].isHittable, "Sidebar New chat should not be the visible affordance when the sidebar is hidden")

        toolbarNewChat.click()
        XCTAssertTrue(app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5))
        try captureScreenshot(named: "00-collapsed-sidebar-new-chat")
    }

    func testMultiTurnMessageLayoutSnapshot() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5))
        selectWelcomeTool("Chat")

        _ = sendPrompt(
            "UI test multi turn first.",
            expecting: "First deterministic turn."
        )
        let secondResponse = sendPrompt(
            "UI test multi turn second.",
            expecting: "Second deterministic turn with prior context."
        )

        XCTAssertGreaterThanOrEqual(messageCount(identifier: "message.user"), 2)
        XCTAssertGreaterThanOrEqual(messageCount(identifier: "message.assistant"), 2)
        assertComposerIsBoundedBottomAccessory()
        assertResponseClearsComposer(secondResponse)
        try captureScreenshot(named: "03-multi-turn")
    }

    func testFullScreenLengthMessageScrollsWithoutCoveringComposer() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5))
        selectWelcomeTool("Chat")

        let responseEnd = sendPrompt(
            "UI test long scroll response.",
            expecting: "Long scroll response ends.",
            waitForUserEcho: false
        )
        let assistantMessage = lastMessage(identifier: "message.assistant")
        let transcript = transcriptElement()
        let composer = app.descendants(matching: .any)["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))

        let visibleTranscriptHeight = composer.frame.minY - transcript.frame.minY - 16
        XCTAssertGreaterThan(
            assistantMessage.frame.height,
            visibleTranscriptHeight,
            "Long assistant response should exceed the visible transcript height and require scrolling"
        )
        XCTAssertTrue(responseEnd.exists)
        assertComposerIsBoundedBottomAccessory()
        try captureScreenshot(named: "04-long-message-scroll")
    }

    func testStreamingScrollKeepsComposerAndTranscriptAnchoredSnapshot() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5))
        selectWelcomeTool("Chat")

        let composerBefore = composerFrame()
        enterPrompt("UI test streaming scroll response.")
        clickGenerate()
        _ = waitForTranscriptMessage(
            identifier: "message.user",
            containing: "UI test streaming scroll response."
        )

        let primaryAction = app.buttons["composer.primaryAction"]
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 5), "Missing composer primary action during streaming")
        XCTAssertTrue(
            primaryAction.label.localizedCaseInsensitiveContains("stop"),
            "Streaming regression check should run while generation is active"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(3.0))

        let midStreamMessage = lastMessage(identifier: "message.assistant")
        let composerDuring = composerFrame()
        let transcript = transcriptElement()

        XCTAssertLessThanOrEqual(
            abs(composerDuring.minY - composerBefore.minY),
            2,
            "Composer should not jump upward while assistant text is streaming"
        )
        XCTAssertLessThan(
            midStreamMessage.frame.minY,
            composerDuring.minY,
            "Streaming assistant text should remain above the floating composer"
        )
        XCTAssertGreaterThan(
            midStreamMessage.frame.maxY,
            transcript.frame.minY,
            "Streaming assistant text should remain inside the transcript rail"
        )
        XCTAssertTrue(
            primaryAction.label.localizedCaseInsensitiveContains("stop"),
            "Mid-stream regression capture should happen while generation is still active"
        )
        assertComposerIsBoundedBottomAccessory()
        try captureScreenshot(named: "04b-streaming-scroll-mid")

        let finalMessage = waitForTranscriptMessage(
            containing: "Streaming scroll response ends.",
            timeout: 25
        )
        let composerAfter = composerFrame()
        XCTAssertLessThanOrEqual(
            abs(composerAfter.minY - composerBefore.minY),
            2,
            "Composer should return to the same bottom anchor after streaming completes"
        )
        XCTAssertTrue(finalMessage.exists)
        try captureScreenshot(named: "04c-streaming-scroll-complete")
    }

    func testMarkdownRenderingSnapshot() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5))
        selectWelcomeTool("Chat")

        let response = sendPrompt(
            "UI test markdown rendering.",
            expecting: "Markdown Rendering Probe"
        )

        XCTAssertTrue(messageElement(response, contains: "bold text"))
        XCTAssertTrue(messageElement(response, contains: "First rendered bullet"))
        XCTAssertTrue(messageElement(response, contains: "let value = \"rendered\""))
        XCTAssertTrue(messageElement(response, contains: "Status"))
        XCTAssertTrue(messageElement(response, contains: "Rendered"))
        XCTAssertFalse(
            app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", "```swift"))
                .element(boundBy: 0)
                .exists,
            "Rendered Markdown should not expose raw code fence markers"
        )

        assertComposerIsBoundedBottomAccessory()
        assertResponseClearsComposer(response)
        try captureScreenshot(named: "05-markdown-rendering")
    }

    func testNarrowWindowMessageAndComposerWidthsSnapshot() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5))
        selectWelcomeTool("Chat")

        _ = sendPrompt(
            "UI test markdown rendering.",
            expecting: "Markdown Rendering Probe"
        )

        let composer = app.descendants(matching: .any)["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Missing composer")
        XCTAssertLessThan(
            app.windows.firstMatch.frame.width,
            980,
            "Narrow-window test did not launch a narrow window"
        )

        let assistantContent = app.descendants(matching: .any)["message.assistant.content"]
        XCTAssertTrue(assistantContent.waitForExistence(timeout: 5), "Missing assistant content")

        assertAssistantContentMatchesComposerRail()
        assertSidebarSelectionAlignsWithSearchRail(maxWidth: 228)
        assertComposerIsBoundedBottomAccessory()
        try captureScreenshot(named: "06-narrow-window-chat")
    }

    func testFullWidthPlainMessageRailSnapshot() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5))
        selectWelcomeTool("Chat")

        let response = sendPrompt(
            "UI test plain rail response.",
            expecting: "Plain rail response begins."
        )

        XCTAssertGreaterThan(
            app.windows.firstMatch.frame.width,
            1200,
            "Full-width rail test did not launch a wide window"
        )
        try captureScreenshot(named: "06b-full-width-plain-rail")
        assertAssistantContentMatchesComposerRail(tolerance: 4)
        assertAssistantTextStaysInsideComposerRail()
        assertLastUserBubbleEndsOnComposerRail(tolerance: 4)
        assertComposerIsBoundedBottomAccessory()
        assertResponseClearsComposer(response)
    }

    func testSidebarRowsKeepTitleReadableSnapshot() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5))
        selectWelcomeTool("Chat")

        _ = sendPrompt(
            "A detailed sidebar title should keep useful words visible.",
            expecting: "UI test chat response"
        )
        createNewChat()
        _ = sendPrompt(
            "Research a deterministic sidebar topic with many words.",
            expecting: "UI test chat response"
        )
        createNewChat()
        _ = sendPrompt(
            "Summarize sidebar row spacing without crowding the title.",
            expecting: "UI test chat response"
        )

        let titles = waitForSidebarElements(identifier: "sidebar.chat.title", minimumCount: 3)
        let previews = waitForSidebarElements(identifier: "sidebar.chat.preview", minimumCount: 3)
        let timestamps = waitForSidebarElements(identifier: "sidebar.chat.timestamp", minimumCount: 3)

        XCTAssertGreaterThan(
            titles[0].frame.width,
            140,
            "The sidebar title should own the first line instead of being squeezed by metadata"
        )
        XCTAssertGreaterThan(
            timestamps[0].frame.minY,
            titles[0].frame.minY + 8,
            "The sidebar timestamp should sit on the preview line, not the title line"
        )
        XCTAssertLessThanOrEqual(
            abs(timestamps[0].frame.midY - previews[0].frame.midY),
            5,
            "The sidebar timestamp should align with the preview baseline"
        )
        let selectedRow = app.descendants(matching: .any)["sidebar.chat.selectedRow"]
        XCTAssertTrue(selectedRow.waitForExistence(timeout: 5), "Missing selected sidebar row frame probe")
        let selectedTimestamp = timestamps.first { timestamp in
            timestamp.frame.midY >= selectedRow.frame.minY
                && timestamp.frame.midY <= selectedRow.frame.maxY
        }
        guard let selectedTimestamp else {
            XCTFail("Missing timestamp inside selected sidebar row")
            return
        }
        let timestampRightInset = selectedRow.frame.maxX - selectedTimestamp.frame.maxX
        XCTAssertGreaterThanOrEqual(
            timestampRightInset,
            -2,
            "Sidebar timestamp should not spill outside the selected row rail"
        )
        XCTAssertLessThanOrEqual(
            timestampRightInset,
            12,
            "Sidebar timestamp should sit on the row's trailing side, not float in the middle"
        )
        assertSidebarSelectionAlignsWithSearchRail()
        try captureScreenshot(named: "06c-sidebar-density")
    }

    func testLongMultilineInputExpandsThenSends() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5))
        selectWelcomeTool("Chat")

        let prompt = longMultilinePrompt()
        pastePrompt(prompt)
        waitForComposerValue(containing: "UI test very long multi-line input")
        waitForComposerValue(containing: "Final line before send.")
        assertComposerExpandsForLongMultilineDraft()
        try captureScreenshot(named: "07-long-multiline-input")

        clickGenerate()
        _ = waitForTranscriptMessage(
            identifier: "message.user",
            containing: "UI test very long multi-line input",
            timeout: 5
        )
        let response = waitForTranscriptMessage(containing: "Long multi-line input accepted.")
        assertComposerIsBoundedBottomAccessory()
        assertResponseClearsComposer(response)
        try captureScreenshot(named: "08-long-multiline-sent")
    }

    func testSingleLineInputKeepsDefaultComposerHeightSnapshot() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5))
        selectWelcomeTool("Chat")

        let initialComposerHeight = composerFrame().height
        let initialInputHeight = composerInputFieldFrame().height
        let longSingleLinePrompt = "Single line composer sizing probe that remains one logical line even when it is long enough to approach the visual wrapping threshold in the composer."
        pastePrompt(longSingleLinePrompt)
        waitForComposerValue(containing: "visual wrapping threshold")
        let editedComposerHeight = composerFrame().height
        let editedInputHeight = composerInputFieldFrame().height

        XCTAssertLessThanOrEqual(
            abs(editedComposerHeight - initialComposerHeight),
            1,
            "A single-line draft should not resize the composer"
        )
        XCTAssertLessThanOrEqual(
            abs(editedInputHeight - initialInputHeight),
            1,
            "A single-line draft should not resize the input field"
        )
        assertComposerIsBoundedBottomAccessory()
        try captureScreenshot(named: "09-single-line-input")
    }

    func testTwoLineInputKeepsDefaultComposerHeightSnapshot() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5))
        selectWelcomeTool("Chat")

        let initialComposerHeight = composerFrame().height
        let initialInputHeight = composerInputFieldFrame().height
        let input = composerInput()
        input.click()
        input.typeText("First logical line")
        input.typeKey(.return, modifierFlags: [.shift])
        input.typeText("Second logical line")
        waitForComposerValue(containing: "Second logical line")

        let editedComposerHeight = composerFrame().height
        let editedInputHeight = composerInputFieldFrame().height
        XCTAssertLessThanOrEqual(
            abs(editedComposerHeight - initialComposerHeight),
            1,
            "A two-line draft should still use the default composer height"
        )
        XCTAssertLessThanOrEqual(
            abs(editedInputHeight - initialInputHeight),
            1,
            "A two-line draft should still use the default input field height"
        )
        assertComposerIsBoundedBottomAccessory()
        try captureScreenshot(named: "09b-two-line-input")
    }

    func testGeneratedImageOutputLayoutSnapshot() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Image"].waitForExistence(timeout: 5))
        selectWelcomeTool("Image")

        enterPrompt("Create a simple gradient square")
        clickGenerate()

        let attachment = waitForGeneratedAttachment(identifier: "generated.image")
        assertGeneratedAttachmentLayout(attachment)
        try captureScreenshot(named: "10-image-output")
    }

    func testGeneratedSpeechOutputLayoutSnapshot() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Speech"].waitForExistence(timeout: 5))
        selectWelcomeTool("Speech")

        enterPrompt("Say this generated speech test sentence")
        clickGenerate()

        let attachment = waitForGeneratedAttachment(identifier: "generated.audio.speech")
        assertGeneratedAttachmentLayout(attachment)
        try captureScreenshot(named: "11-speech-output")
    }

    func testGeneratedMusicOutputLayoutSnapshot() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Music"].waitForExistence(timeout: 5))
        selectWelcomeTool("Music")

        enterPrompt("Moody cyberpunk instrumental music")
        assertMusicLyricsEditorHiddenForInstrumentalPrompt()
        clickGenerate()

        let attachment = waitForGeneratedAttachment(identifier: "generated.audio.music")
        assertGeneratedAttachmentLayout(attachment)
        try captureScreenshot(named: "12-music-output")
    }

    func testMusicWithVocalsDraftLayoutSnapshot() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Music"].waitForExistence(timeout: 5))
        selectWelcomeTool("Music")

        enterPrompt("Moody synth pop with vocals")
        selectMusicVocalMode("With vocals")
        assertMusicLyricsEditorVisibleForVocalsMode()
        assertMusicLyricsControlsAlignWithComposerInput()
        enterMusicLyrics("First verse line\nSecond verse line")
        assertComposerStaysUsableWithMusicControls()
        try captureScreenshot(named: "13-music-with-vocals-draft")
    }

    func testTranscriptLiftsAboveExpandedMusicComposerSnapshot() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Music"].waitForExistence(timeout: 5))
        selectWelcomeTool("Music")

        enterPrompt("Moody cyberpunk instrumental music")
        clickGenerate()

        let attachmentBeforeExpansion = waitForGeneratedAttachment(identifier: "generated.audio.music")
        assertGeneratedAttachmentLayout(attachmentBeforeExpansion)
        let compactComposer = composerFrame()

        enterPrompt("Moody synth pop with vocals")
        selectMusicVocalMode("With vocals")
        assertMusicLyricsEditorVisibleForVocalsMode()
        waitForTransientUIToSettle()

        let expandedComposer = composerFrame()
        XCTAssertGreaterThan(
            expandedComposer.height,
            compactComposer.height + 80,
            "With vocals mode should expand the composer enough to exercise transcript layout"
        )

        let attachmentAfterExpansion = waitForGeneratedAttachment(identifier: "generated.audio.music")
        XCTAssertLessThan(
            attachmentAfterExpansion.frame.maxY,
            expandedComposer.minY - 8,
            "Transcript content should move above the expanded music composer instead of stacking underneath it"
        )
        try captureScreenshot(named: "13b-expanded-music-composer-transcript")
    }

    func testToolSelectorPopoverLayoutSnapshot() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5))

        let toolSelector = app.buttons["composer.toolSelector"]
        XCTAssertTrue(toolSelector.waitForExistence(timeout: 5), "Missing composer tool selector")
        toolSelector.click()

        let chatTool = app.descendants(matching: .any)["tool.Chat"]
        XCTAssertTrue(chatTool.waitForExistence(timeout: 5), "Tool selector popover did not open")
        XCTAssertFalse(app.staticTexts["Recommended"].exists, "Recommendation labels belong only in the Models settings page")
        try captureScreenshot(named: "14-tool-selector-popover")
    }

    func testComposerModelLoadingIndicatorDoesNotResizeComposer() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5))

        assertComposerIsBoundedBottomAccessory()

        let indicator = app.descendants(matching: .any)["composer.modelLoadingIndicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 2), "Missing compact composer model loading indicator")
        XCTAssertLessThanOrEqual(
            composerFrame().height,
            170,
            "Model loading state should not expand the composer"
        )
        XCTAssertLessThanOrEqual(
            indicator.frame.height,
            4,
            "Composer loading indicator should stay as a compact line"
        )

        try captureScreenshot(named: "15-composer-model-loading")
    }

    func testComposerModelPickerShowsReadyModelsOnlySnapshot() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5))

        let dropdown = app.buttons["composer.modelDropdown"]
        XCTAssertTrue(dropdown.waitForExistence(timeout: 5), "Missing composer model picker")
        dropdown.click()

        let readyRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "composer.modelProfile."))
            .element(boundBy: 0)
        XCTAssertTrue(readyRow.waitForExistence(timeout: 5), "Composer model picker should show at least one ready model")
        XCTAssertFalse(app.staticTexts["Recommended"].exists, "Composer model picker should not show catalog recommendation labels")
        XCTAssertFalse(app.staticTexts["Ready"].exists, "Composer model picker should not show redundant ready badges")
        XCTAssertFalse(app.staticTexts["Missing"].exists, "Composer model picker should hide missing models")
        XCTAssertFalse(app.staticTexts["Downloading"].exists, "Composer model picker should hide downloading models")
        XCTAssertFalse(app.staticTexts["Paused"].exists, "Composer model picker should hide paused models")
        XCTAssertFalse(app.staticTexts["No ready models"].exists, "Fixture includes a ready model, so the empty state should not appear")

        try captureScreenshot(named: "15b-composer-model-picker-ready-only")
    }

    func testModelParameterPopoverLayoutSnapshot() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5))

        let parameters = app.buttons["composer.modelSettings"]
        XCTAssertTrue(parameters.waitForExistence(timeout: 5), "Missing composer model settings button")
        parameters.click()

        waitForTransientUIToSettle()
        XCTAssertFalse(app.staticTexts["Recommended"].exists, "Model fit labels belong only in the Models settings page")
        try captureScreenshot(named: "16-model-parameters-popover")
    }

    func testLocalEngineStatusPopoverLayoutSnapshot() throws {
        XCTAssertTrue(app.buttons["welcome.tool.Chat"].waitForExistence(timeout: 5))
        selectWelcomeTool("Chat")

        _ = sendPrompt(
            "UI test engine status popover.",
            expecting: "UI test chat response"
        )

        let status = app.buttons["composer.modelStatus"]
        guard status.waitForExistence(timeout: 5) else {
            throw XCTSkip("Composer model status is hidden for this deterministic UI-test state")
        }

        status.click()
        waitForTransientUIToSettle()
        try captureScreenshot(named: "17-local-engine-status-popover")
    }

    func testSettingsWindowLayoutSnapshot() throws {
        openSettingsWindow()

        let settingsWindow = app.descendants(matching: .any)["settings.window"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5), "Settings window did not open")
        let window = app.windows["MLXHub Settings"]
        if window.waitForExistence(timeout: 2) {
            window.click()
        }
        waitForTransientUIToSettle()
        assertSettingsModelLayoutIsAligned()
        try captureScreenshot(named: "18-settings-models")
    }

    @discardableResult
    private func sendPrompt(
        _ prompt: String,
        expecting expectedResponse: String,
        waitForUserEcho: Bool = true
    ) -> XCUIElement {
        enterPrompt(prompt)
        clickGenerate()
        if waitForUserEcho {
            _ = waitForTranscriptMessage(
                identifier: "message.user",
                containing: prompt
            )
        }
        return waitForTranscriptMessage(containing: expectedResponse)
    }

    private func selectWelcomeTool(_ toolId: String) {
        let button = app.buttons
            .matching(identifier: "welcome.tool.\(toolId)")
            .element(boundBy: 0)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing \(toolId) chip")
        button.click()
    }

    private func assertWelcomePromptChipsLookClickable() {
        let chipTitles = [
            "Ask",
            "Analyze image",
            "Create image",
            "Create speech",
            "Make music",
            "Research"
        ]
        let chips = chipTitles.map { title in
            let chip = app.buttons
                .matching(NSPredicate(format: "label == %@", title))
                .element(boundBy: 0)
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "Missing welcome chip \(title)")
            XCTAssertTrue(chip.isHittable, "Welcome chip \(title) should be directly clickable")
            XCTAssertGreaterThanOrEqual(chip.frame.height, 36, "Welcome chip \(title) should have a visible command surface")
            XCTAssertGreaterThanOrEqual(chip.frame.width, 140, "Welcome chip \(title) should read as a button, not loose text")
            return chip
        }

        let firstHeight = chips.first?.frame.height ?? 0
        for chip in chips.dropFirst() {
            XCTAssertLessThanOrEqual(
                abs(chip.frame.height - firstHeight),
                1,
                "Welcome chips should share a consistent command height"
            )
        }
    }

    private func assertSidebarHeaderPlacesNewChatAboveSearch() {
        let newChatButton = app.buttons["sidebar.newChat"]
        XCTAssertTrue(newChatButton.waitForExistence(timeout: 5), "Missing sidebar New chat button")

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Missing sidebar search field")
        XCTAssertLessThanOrEqual(
            newChatButton.frame.maxY,
            searchField.frame.minY,
            "Sidebar New chat should sit above Search"
        )
    }

    private func assertInitialDraftChatIsUntitled() {
        let title = app.descendants(matching: .any)["sidebar.chat.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Missing initial sidebar chat title")
        let titleText = title.label.isEmpty ? (title.value as? String ?? "") : title.label
        XCTAssertEqual(
            titleText,
            "Untitled",
            "Empty draft chats should not appear in history as New chat"
        )
    }

    private func createNewChat() {
        let button = app.buttons["sidebar.newChat"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing new chat sidebar button")
        button.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func openSettingsWindow() {
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

    private func waitForTransientUIToSettle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    private func assertSettingsModelLayoutIsAligned() {
        let modePicker = app.descendants(matching: .any)["settings.modelModePicker"]
        let search = app.descendants(matching: .any)["settings.modelSearch"]
        let sectionHeader = app.descendants(matching: .any)
            .matching(identifier: "settings.modelSectionHeader")
            .firstMatch
        let modelList = app.descendants(matching: .any)["settings.modelList"]
        let firstModelTitle = app.staticTexts["Gemma 4"]
        let readyAction = app.buttons["Use for Chat"].firstMatch
        let moreAction = app.descendants(matching: .any)
            .matching(identifier: "settings.modelState.moreActions")
            .firstMatch

        XCTAssertTrue(modePicker.waitForExistence(timeout: 5), "Missing settings mode picker")
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Missing settings model search")
        XCTAssertTrue(sectionHeader.waitForExistence(timeout: 5), "Missing settings model section header")
        XCTAssertTrue(modelList.waitForExistence(timeout: 5), "Missing settings model list")
        XCTAssertTrue(firstModelTitle.waitForExistence(timeout: 5), "Missing first model title")
        XCTAssertTrue(readyAction.waitForExistence(timeout: 5), "Missing ready model action")
        XCTAssertTrue(moreAction.waitForExistence(timeout: 5), "Missing row more action")

        XCTAssertLessThanOrEqual(
            abs(modePicker.frame.minX - sectionHeader.frame.minX),
            8,
            "Mode picker should align with the model section rail"
        )
        XCTAssertLessThanOrEqual(
            abs(moreAction.frame.maxX - search.frame.maxX),
            28,
            "Row actions and search should sit on a consistent trailing rail"
        )
        XCTAssertLessThan(
            readyAction.frame.maxX,
            moreAction.frame.minX,
            "Primary row action should leave a stable gutter before the more menu"
        )
    }

    private func enterPrompt(_ text: String) {
        let input = composerInput()
        input.click()
        input.typeText(text)

        let inputValue = String(describing: input.value ?? "")
        XCTAssertTrue(
            inputValue.contains(text),
            "Composer input did not receive prompt text. Current value: \(inputValue)"
        )
    }

    private func pastePrompt(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string))

        let input = composerInput()
        input.click()
        input.typeKey("v", modifierFlags: .command)
    }

    private func waitForComposerValue(
        containing text: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let input = composerInput()
            let inputValue = String(describing: input.value ?? "")
            if inputValue.contains(text) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        let inputValue = String(describing: composerInput().value ?? "")
        XCTFail(
            "Composer input did not contain \(text). Current value: \(inputValue)",
            file: file,
            line: line
        )
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

    private func composerInputFieldFrame() -> CGRect {
        let field = app.scrollViews["composer.inputField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        return field.frame
    }

    private func composerVisualInputBoxFrame() -> CGRect {
        let textField = composerInputFieldFrame()
        let fieldHorizontalPadding: CGFloat = 14
        let fieldVerticalPadding: CGFloat = 2
        return textField.insetBy(dx: -fieldHorizontalPadding, dy: -fieldVerticalPadding)
    }

    private func musicLyricsInput() -> XCUIElement {
        let textView = app.textViews["composer.musicLyricsInput"]
        if textView.waitForExistence(timeout: 5) {
            return textView
        }

        let anyElement = app.descendants(matching: .any)["composer.musicLyricsInput"]
        XCTAssertTrue(anyElement.waitForExistence(timeout: 5))
        return anyElement
    }

    private func musicLyricsInputFrame() -> CGRect {
        let field = app.scrollViews["composer.musicLyricsInput"]
        if field.waitForExistence(timeout: 5) {
            return field.frame
        }

        let anyElement = app.descendants(matching: .any)["composer.musicLyricsInput"]
        XCTAssertTrue(anyElement.waitForExistence(timeout: 5))
        return anyElement.frame
    }

    private func musicLyricsVisualInputBoxFrame() -> CGRect {
        let textField = musicLyricsInputFrame()
        let fieldHorizontalPadding: CGFloat = 14
        let fieldVerticalPadding: CGFloat = 2
        return textField.insetBy(dx: -fieldHorizontalPadding, dy: -fieldVerticalPadding)
    }

    private func enterMusicLyrics(_ text: String) {
        let input = musicLyricsInput()
        input.click()
        input.typeText(text)

        let inputValue = String(describing: input.value ?? "")
        XCTAssertTrue(
            inputValue.contains("First verse line") && inputValue.contains("Second verse line"),
            "Lyrics input did not receive multi-line text. Current value: \(inputValue)"
        )
    }

    private func clickGenerate() {
        let button = app.buttons["composer.primaryAction"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isEnabled, "Composer primary action should be enabled after entering text")
        button.click()
    }

    private func composerFrame() -> CGRect {
        let composer = app.descendants(matching: .any)["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Missing composer container")
        return composer.frame
    }

    private func messageCount(identifier: String) -> Int {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .allElementsBoundByIndex
            .filter(\.exists)
            .count
    }

    private func lastMessage(identifier: String) -> XCUIElement {
        let messages = app.descendants(matching: .any)
            .matching(identifier: identifier)
            .allElementsBoundByIndex
            .filter(\.exists)
        XCTAssertFalse(messages.isEmpty, "Missing \(identifier)")
        return messages.last ?? app.descendants(matching: .any)[identifier]
    }

    private func transcriptElement() -> XCUIElement {
        let scrollView = app.scrollViews["chat.transcript"]
        if scrollView.waitForExistence(timeout: 5) {
            return scrollView
        }

        let anyElement = app.descendants(matching: .any)["chat.transcript"]
        XCTAssertTrue(anyElement.waitForExistence(timeout: 5), "Missing transcript")
        return anyElement
    }

    private func waitForTranscriptMessage(
        identifier: String = "message.assistant",
        containing text: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let transcriptFrame = transcriptElement().frame
        let query = app.descendants(matching: .any)
            .matching(identifier: identifier)

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let matchingElement = query.allElementsBoundByIndex.first { element in
                element.exists
                    && element.frame.maxX > transcriptFrame.minX
                    && element.frame.minX < transcriptFrame.maxX
                    && messageElement(element, contains: text)
            }

            if let matchingElement {
                return matchingElement
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        XCTFail("Missing \(identifier) containing \"\(text)\"", file: file, line: line)
        return query.element(boundBy: 0)
    }

    private func messageElement(_ element: XCUIElement, contains text: String) -> Bool {
        if element.label.contains(text) {
            return true
        }

        if let value = element.value as? String, value.contains(text) {
            return true
        }

        let contentPredicate = NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            text,
            text
        )
        return element.descendants(matching: .any)
            .matching(contentPredicate)
            .element(boundBy: 0)
            .exists
    }

    private func assertComposerIsBoundedBottomAccessory() {
        let window = app.windows.firstMatch
        let composer = app.descendants(matching: .any)["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Missing composer container")

        XCTAssertGreaterThan(
            composer.frame.minY,
            window.frame.maxY - 190,
            "Composer drifted too far above the bottom edge"
        )
        XCTAssertLessThan(
            composer.frame.height,
            170,
            "Composer should stay bounded in the default text-only state"
        )
    }

    private func assertComposerModelControlReplacesToolbarControls() {
        let toolSelector = app.buttons["composer.toolSelector"]
        let modelControl = app.descendants(matching: .any)["composer.modelControl"]
        let modelSettings = app.buttons["composer.modelSettings"]
        let modelStatus = app.buttons["composer.modelStatus"]
        let primaryAction = app.buttons["composer.primaryAction"]

        XCTAssertTrue(toolSelector.waitForExistence(timeout: 5), "Existing tool selector moved or disappeared")
        XCTAssertTrue(modelControl.waitForExistence(timeout: 5), "Missing composer model control")
        XCTAssertTrue(modelSettings.waitForExistence(timeout: 5), "Missing composer model settings segment")
        XCTAssertTrue(modelStatus.waitForExistence(timeout: 5), "Missing composer model status segment")
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 5), "Missing composer send/stop button")

        XCTAssertLessThan(
            modelControl.frame.maxX,
            primaryAction.frame.minX + 1,
            "Composer model control should sit immediately left of Send/Stop"
        )
        XCTAssertLessThan(
            toolSelector.frame.maxX,
            modelControl.frame.minX,
            "Tool selector should remain on the left side of the composer row"
        )
        XCTAssertFalse(
            app.buttons["toolbar.modelParameters"].exists,
            "Model parameters should no longer be exposed in the toolbar"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["localEngine.status"].exists,
            "Local engine status should no longer be exposed as a toolbar pill"
        )
    }

    private func assertComposerExpandsForLongMultilineDraft() {
        let window = app.windows.firstMatch
        let composer = app.descendants(matching: .any)["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Missing composer container")

        XCTAssertGreaterThan(
            composer.frame.height,
            190,
            "Composer should expand for a long multi-line draft"
        )
        XCTAssertLessThan(
            composer.frame.height,
            300,
            "Composer should cap long drafts and scroll internally"
        )
        XCTAssertGreaterThan(
            composer.frame.minY,
            window.frame.maxY - 320,
            "Expanded composer drifted too far above the bottom edge"
        )
        XCTAssertLessThan(
            composer.frame.maxY,
            window.frame.maxY - 4,
            "Expanded composer should remain inside the window"
        )
    }

    private func waitForGeneratedAttachment(
        identifier: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let query = app.descendants(matching: .any)
            .matching(identifier: identifier)
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            let matches = query.allElementsBoundByIndex.filter(\.exists)
            if let attachment = matches.max(by: { lhs, rhs in
                lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
            }) {
                return attachment
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        XCTFail("Missing generated attachment \(identifier)", file: file, line: line)
        return query.element(boundBy: 0)
    }

    private func assertGeneratedAttachmentLayout(_ attachment: XCUIElement) {
        let composer = app.descendants(matching: .any)["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Missing composer container")

        XCTAssertGreaterThan(
            attachment.frame.width,
            240,
            "Generated media should render as a readable card, not a tiny attachment"
        )
        XCTAssertLessThanOrEqual(
            attachment.frame.width,
            620,
            "Generated media should stay within the transcript column"
        )
        XCTAssertLessThan(
            attachment.frame.maxY,
            composer.frame.minY - 8,
            "Generated media is colliding with the floating composer"
        )
    }

    private func assertMusicLyricsEditorHiddenForInstrumentalPrompt() {
        let lyricsEditor = app.descendants(matching: .any)["composer.musicLyricsEditor"]
        XCTAssertFalse(
            lyricsEditor.exists,
            "Instrumental music prompts in Auto mode should not open the lyrics editor"
        )
    }

    private func selectMusicVocalMode(_ title: String) {
        let radioButton = app.radioButtons[title]
        if radioButton.waitForExistence(timeout: 2) {
            radioButton.click()
            return
        }

        let directButton = app.buttons[title]
        if directButton.waitForExistence(timeout: 2) {
            directButton.click()
            return
        }

        let segmentedButton = app.segmentedControls.buttons[title]
        if segmentedButton.waitForExistence(timeout: 2) {
            segmentedButton.click()
            return
        }

        let predicate = NSPredicate(format: "label == %@", title)
        let fallback = app.descendants(matching: .any)
            .matching(predicate)
            .element(boundBy: 0)
        XCTAssertTrue(fallback.waitForExistence(timeout: 5), "Missing music vocal mode \(title)")
        fallback.click()
    }

    private func assertMusicLyricsEditorVisibleForVocalsMode() {
        let lyricsEditor = app.descendants(matching: .any)["composer.musicLyricsEditor"]
        XCTAssertTrue(
            lyricsEditor.waitForExistence(timeout: 5),
            "With vocals mode should show the compact lyrics editor"
        )
    }

    private func assertMusicLyricsControlsAlignWithComposerInput() {
        let composerRail = composerInputFieldFrame()
        let composerBox = composerVisualInputBoxFrame()
        let lyricsBox = musicLyricsVisualInputBoxFrame()
        let vocalsLabel = app.staticTexts["Vocals"]

        XCTAssertTrue(vocalsLabel.waitForExistence(timeout: 5), "Missing vocals label")

        XCTAssertLessThanOrEqual(
            abs(lyricsBox.minX - composerBox.minX),
            3,
            "Lyrics field should align with the primary composer field leading edge"
        )
        XCTAssertLessThanOrEqual(
            abs(lyricsBox.maxX - composerBox.maxX),
            3,
            "Lyrics field should align with the primary composer field trailing edge"
        )
        XCTAssertLessThanOrEqual(
            abs(vocalsLabel.frame.minX - composerRail.minX),
            4,
            "Vocals label should align to the composer text rail"
        )
    }

    private func assertComposerStaysUsableWithMusicControls() {
        let window = app.windows.firstMatch
        let composer = app.descendants(matching: .any)["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Missing composer container")

        XCTAssertLessThan(
            composer.frame.height,
            330,
            "Music controls should not turn the composer into a full settings form"
        )
        XCTAssertGreaterThan(
            composer.frame.minY,
            window.frame.maxY - 360,
            "Music controls should keep the composer anchored as a bottom accessory"
        )
    }

    private func assertResponseClearsComposer(_ response: XCUIElement) {
        let window = app.windows.firstMatch
        let composer = app.descendants(matching: .any)["chat.composer"]
        XCTAssertGreaterThan(
            response.frame.minY,
            window.frame.minY + 44,
            "Assistant response is overlapping the toolbar/titlebar region"
        )
        XCTAssertLessThan(
            response.frame.maxY,
            composer.frame.minY - 8,
            "Assistant response is colliding with the floating composer"
        )
    }

    private func assertPerformanceMetricsAreHoverOnly() {
        let metrics = app.staticTexts["message.performanceMetrics"]

        XCTAssertFalse(
            metrics.exists,
            "Performance metrics should stay hidden until hover so they do not create a persistent metadata row"
        )
    }

    private func assertHoverAccessoriesDoNotMoveComposer(
        _ assistantMessage: XCUIElement,
        expectedCopiedText: String
    ) {
        let initialComposerFrame = composerFrame()
        let hoverPoint = assistantMessage.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        hoverPoint.hover()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))

        let hoverAccessory = app.descendants(matching: .any)["message.hoverAccessories"]
        if !hoverAccessory.waitForExistence(timeout: 1) {
            assistantMessage.click()
        }
        XCTAssertTrue(
            hoverAccessory.waitForExistence(timeout: 2),
            "Assistant hover accessories should appear for this regression check"
        )

        let deadline = Date().addingTimeInterval(2)
        var assistantText: XCUIElement?
        repeat {
            assistantText = app.staticTexts
                .matching(identifier: "message.assistant.plainText")
                .allElementsBoundByIndex
                .first { element in
                    element.exists
                        && (
                            (element.value as? String)?.contains(expectedCopiedText) == true
                                || element.label.contains(expectedCopiedText)
                        )
                }
            if assistantText != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        guard let assistantText else {
            XCTFail("Missing copied response text")
            return
        }
        XCTAssertGreaterThanOrEqual(
            hoverAccessory.frame.minY,
            assistantText.frame.maxY - 1,
            "Assistant hover accessories should sit under the assistant message text"
        )

        let copyButton = app.buttons["message.copy"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 2), "Missing assistant copy button")

        let metrics = app.descendants(matching: .any)["message.performanceMetrics"]
        if metrics.exists {
            XCTAssertLessThanOrEqual(
                copyButton.frame.minX,
                metrics.frame.minX,
                "Copy should be the first assistant hover accessory"
            )
        }

        XCTAssertGreaterThan(
            copyButton.frame.width,
            12,
            "Assistant copy button should expose a usable visible target"
        )

        let hoveredComposerFrame = composerFrame()
        XCTAssertLessThanOrEqual(
            abs(hoveredComposerFrame.minY - initialComposerFrame.minY),
            1,
            "Hover-only message accessories should not move the floating composer"
        )
        XCTAssertLessThanOrEqual(
            abs(hoveredComposerFrame.height - initialComposerFrame.height),
            1,
            "Hover-only message accessories should not change composer height"
        )
    }

    private func assertUserHoverAccessoriesSitUnderSentMessage(expectedCopiedText: String) {
        let initialComposerFrame = composerFrame()
        let userBubble = app.descendants(matching: .any)["message.user.bubble"]
        XCTAssertTrue(userBubble.waitForExistence(timeout: 5), "Missing sent message bubble")

        userBubble.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))

        let userAccessory = app.descendants(matching: .any)["message.user.hoverAccessories"]
        XCTAssertTrue(
            userAccessory.waitForExistence(timeout: 2),
            "Sent message hover accessories should appear below the bubble"
        )
        XCTAssertGreaterThanOrEqual(
            userAccessory.frame.minY,
            userBubble.frame.maxY - 1,
            "Sent message time/copy controls should sit under the bubble, not on top of it"
        )

        let copyButton = app.buttons["message.user.copy"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 2), "Missing sent message copy button")
        XCTAssertGreaterThanOrEqual(
            copyButton.frame.maxX,
            userBubble.frame.maxX - 24,
            "Sent message copy action should sit on the trailing side"
        )
        NSPasteboard.general.clearContents()
        copyButton.click()
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            expectedCopiedText,
            "Sent message copy action should copy the user message text"
        )

        let hoveredComposerFrame = composerFrame()
        XCTAssertLessThanOrEqual(
            abs(hoveredComposerFrame.minY - initialComposerFrame.minY),
            1,
            "Sent message hover accessories should not move the floating composer"
        )
    }

    private func assertAssistantContentMatchesComposerRail(tolerance: CGFloat = 6) {
        let inputFieldFrame = composerVisualInputBoxFrame()
        let assistantContent = app.descendants(matching: .any)["message.assistant.content"]
        XCTAssertTrue(assistantContent.waitForExistence(timeout: 5), "Missing assistant content")

        XCTAssertLessThanOrEqual(
            abs(assistantContent.frame.minX - inputFieldFrame.minX),
            tolerance,
            "Assistant content should share the visible composer input box leading edge"
        )
        XCTAssertLessThanOrEqual(
            abs(assistantContent.frame.maxX - inputFieldFrame.maxX),
            tolerance,
            "Assistant content should share the visible composer input box trailing edge"
        )
    }

    private func assertAssistantTextStaysInsideComposerRail(tolerance: CGFloat = 3) {
        let inputFieldFrame = composerVisualInputBoxFrame()
        let nativeTextView = app.descendants(matching: .any)
            .matching(identifier: "message.assistant.nativeTextView")
            .firstMatch
        let plainText = app.staticTexts
            .matching(identifier: "message.assistant.plainText")
            .firstMatch
        let assistantText = nativeTextView.waitForExistence(timeout: 1) ? nativeTextView : plainText
        XCTAssertTrue(assistantText.waitForExistence(timeout: 5), "Missing assistant text element")

        XCTAssertGreaterThanOrEqual(
            assistantText.frame.minX,
            inputFieldFrame.minX - tolerance,
            "Assistant text should not paint before the composer input rail"
        )
        XCTAssertLessThanOrEqual(
            assistantText.frame.maxX,
            inputFieldFrame.maxX + tolerance,
            "Assistant text should not paint after the composer input rail"
        )
    }

    private func assertLastUserBubbleEndsOnComposerRail(tolerance: CGFloat = 6) {
        let inputFieldFrame = composerVisualInputBoxFrame()
        let bubbles = app.descendants(matching: .any)
            .matching(identifier: "message.user.bubble")
            .allElementsBoundByIndex
            .filter(\.exists)
        XCTAssertFalse(bubbles.isEmpty, "Missing user bubble probe")
        guard let bubble = bubbles.last else { return }

        XCTAssertLessThanOrEqual(
            bubble.frame.maxX,
            inputFieldFrame.maxX + tolerance,
            "User bubble should not extend beyond the composer input rail"
        )
        XCTAssertGreaterThanOrEqual(
            bubble.frame.maxX,
            inputFieldFrame.maxX - tolerance,
            "User bubble trailing edge should share the composer input rail"
        )
    }

    private func assertSidebarSelectionAlignsWithSearchRail(maxWidth: CGFloat = 280) {
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Missing sidebar search field")

        let selectedRow = app.descendants(matching: .any)["sidebar.chat.selectedRow"]
        XCTAssertTrue(selectedRow.waitForExistence(timeout: 5), "Missing selected sidebar row frame probe")

        XCTAssertLessThanOrEqual(
            abs(selectedRow.frame.minX - searchField.frame.minX),
            12,
            "Selected sidebar row should share the native search field rail"
        )
        XCTAssertLessThanOrEqual(
            abs(selectedRow.frame.maxX - searchField.frame.maxX),
            12,
            "Selected sidebar row should share the native search field rail"
        )
        XCTAssertLessThanOrEqual(
            selectedRow.frame.width,
            maxWidth,
            "Sidebar row should not imply an oversized sidebar"
        )
    }

    private func assertSidebarHoverActionUsesBalancedInsets(tolerance: CGFloat = 4) {
        let selectedRow = app.descendants(matching: .any)["sidebar.chat.selectedRow"]
        XCTAssertTrue(selectedRow.waitForExistence(timeout: 5), "Missing selected sidebar row frame probe")

        let icons = app.descendants(matching: .any)
            .matching(identifier: "sidebar.chat.icon")
            .allElementsBoundByIndex
            .filter { icon in
                icon.exists
                    && icon.frame.minX >= selectedRow.frame.minX
                    && icon.frame.maxX <= selectedRow.frame.maxX
                    && icon.frame.midY >= selectedRow.frame.minY
                    && icon.frame.midY <= selectedRow.frame.maxY
            }
        guard let rowIcon = icons.first else {
            XCTFail("Missing selected sidebar row icon")
            return
        }

        rowIcon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let actionButton = app.descendants(matching: .any)["sidebar.chat.actions"]
        XCTAssertTrue(actionButton.waitForExistence(timeout: 2), "Missing sidebar actions button on row hover")

        let leftInset = rowIcon.frame.minX - selectedRow.frame.minX
        let rightInset = selectedRow.frame.maxX - actionButton.frame.maxX
        XCTAssertLessThanOrEqual(
            abs(leftInset - rightInset),
            tolerance,
            "Sidebar hover action should use the same small inset as the row icon"
        )
    }

    private func waitForSidebarElements(
        identifier: String,
        minimumCount: Int,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [XCUIElement] {
        let query = app.descendants(matching: .any).matching(identifier: identifier)
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            let elements = query.allElementsBoundByIndex.filter(\.exists)
            if elements.count >= minimumCount {
                return elements
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        let elements = query.allElementsBoundByIndex.filter(\.exists)
        XCTFail(
            "Expected at least \(minimumCount) sidebar elements for \(identifier), found \(elements.count)",
            file: file,
            line: line
        )
        return elements
    }

    private func assertLocalEngineStatusIsNotLoading() {
        let status = app.descendants(matching: .any)["composer.modelControl"]
        guard status.exists else { return }

        XCTAssertFalse(
            status.label.localizedCaseInsensitiveContains("loading"),
            "Local engine status should leave the loading state after a deterministic response completes"
        )
    }

    private func captureScreenshot(named name: String) throws {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let fileURL = screenshotDirectory.appendingPathComponent("\(name).png")
        try screenshot.pngRepresentation.write(to: fileURL, options: [.atomic])
        print("Saved UI screenshot: \(fileURL.path)")
    }

    private func longMultilinePrompt() -> String {
        var lines = ["UI test very long multi-line input"]
        for index in 1...18 {
            lines.append("Draft line \(index): keep this pasted prompt readable while the composer grows and then scrolls internally.")
        }
        lines.append("Final line before send.")
        return lines.joined(separator: "\n")
    }
}
