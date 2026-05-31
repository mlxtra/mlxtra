import XCTest
@testable import MLXtra

final class ChatMusicToolPlanBuilderTests: XCTestCase {
    func testParametersCoerceDecodedArgumentsAndPreserveSeedZero() {
        var fallbackProbe: String?

        let parameters = ChatMusicToolPlanBuilder.makeParameters(
            prompt: "fallback prompt",
            decodedArguments: [
                "caption": "Night drive",
                "lyrics": "",
                "duration": "12",
                "instrumental": "false",
                "bpm": "128",
                "keyscale": "C minor",
                "timesignature": "4/4",
                "vocal_language": "en"
            ],
            executionParameters: [
                "seed": 0,
                "inference_steps": 8
            ],
            composerSelection: ChatMusicComposerSelection(mode: .auto, approvedLyrics: nil),
            applyAutomaticInstrumentalFallback: true,
            promptSoundsVocal: { text in
                fallbackProbe = text
                return true
            }
        )

        XCTAssertEqual(parameters["caption"] as? String, "Night drive")
        XCTAssertEqual(parameters["lyrics"] as? String, "")
        XCTAssertEqual(parameters["duration"] as? Int, 12)
        XCTAssertEqual(parameters["instrumental"] as? Bool, false)
        XCTAssertEqual(parameters["bpm"] as? Int, 128)
        XCTAssertEqual(parameters["keyscale"] as? String, "C minor")
        XCTAssertEqual(parameters["timesignature"] as? String, "4/4")
        XCTAssertEqual(parameters["vocal_language"] as? String, "en")
        XCTAssertEqual(parameters["seed"] as? Int, 0)
        XCTAssertEqual(parameters["inference_steps"] as? Int, 8)
        XCTAssertEqual(fallbackProbe, "fallback prompt Night drive")
    }

    func testParametersApplyComposerOverridesAfterDecodedArguments() {
        let instrumentalParameters = ChatMusicToolPlanBuilder.makeParameters(
            prompt: "piano cue",
            decodedArguments: [
                "lyrics": "replace this lyric",
                "instrumental": false
            ],
            executionParameters: [:],
            composerSelection: ChatMusicComposerSelection(mode: .instrumental, approvedLyrics: nil),
            applyAutomaticInstrumentalFallback: true,
            promptSoundsVocal: { _ in true }
        )

        XCTAssertEqual(instrumentalParameters["instrumental"] as? Bool, true)
        XCTAssertEqual(instrumentalParameters["lyrics"] as? String, "[Instrumental]")

        let vocalParameters = ChatMusicToolPlanBuilder.makeParameters(
            prompt: "vocal song",
            decodedArguments: [
                "lyrics": "drafted lyric",
                "instrumental": true
            ],
            executionParameters: [:],
            composerSelection: ChatMusicComposerSelection(
                mode: .vocals,
                approvedLyrics: "approved lyric"
            ),
            applyAutomaticInstrumentalFallback: true,
            promptSoundsVocal: { _ in true }
        )

        XCTAssertEqual(vocalParameters["instrumental"] as? Bool, false)
        XCTAssertEqual(vocalParameters["lyrics"] as? String, "approved lyric")
    }

    func testParametersApplyAutomaticInstrumentalFallbackOnlyForNonVocalPrompts() {
        let parameters = ChatMusicToolPlanBuilder.makeParameters(
            prompt: "ambient cue",
            decodedArguments: ["caption": "soft night texture"],
            executionParameters: [:],
            composerSelection: ChatMusicComposerSelection(mode: .auto, approvedLyrics: nil),
            applyAutomaticInstrumentalFallback: true,
            promptSoundsVocal: { _ in false }
        )

        XCTAssertEqual(parameters["instrumental"] as? Bool, true)
        XCTAssertEqual(parameters["lyrics"] as? String, "[Instrumental]")
    }

    func testDirectMusicParametersSkipAutomaticInstrumentalFallback() {
        let parameters = ChatMusicToolPlanBuilder.makeParameters(
            prompt: "ambient cue",
            decodedArguments: nil,
            executionParameters: [:],
            composerSelection: ChatMusicComposerSelection(mode: .auto, approvedLyrics: nil),
            applyAutomaticInstrumentalFallback: false,
            promptSoundsVocal: { _ in false }
        )

        XCTAssertEqual(parameters["caption"] as? String, "ambient cue")
        XCTAssertEqual(parameters["instrumental"] as? Bool, false)
        XCTAssertNil(parameters["lyrics"])
    }

    func testPlanBuildsMusicRequestAndToolCallDetails() throws {
        let musicProfile = makeProfile(
            id: "music",
            name: "ACE-Step",
            modelId: "ACE-Step/acestep-v15-turbo-continuous",
            modality: .music,
            backend: .music
        )
        let outputDirectory = URL(fileURLWithPath: "/tmp/music")
        let parameters: [String: Any] = [
            "caption": "Night drive",
            "lyrics": "[Instrumental]",
            "duration": 30,
            "instrumental": true,
            "seed": 0
        ]

        let plan = ChatMusicToolPlanBuilder.makePlan(
            parameters: parameters,
            fallbackPrompt: "fallback prompt",
            musicProfile: musicProfile,
            outputDirectory: outputDirectory
        )

        XCTAssertEqual(plan.functionName, "generate_music")
        XCTAssertEqual(plan.toolName, "Music generation")
        XCTAssertEqual(plan.status, "Night drive")
        XCTAssertEqual(plan.icon, "music.note")
        XCTAssertEqual(plan.details, [
            ToolCallDetail(label: "Caption", value: "Night drive"),
            ToolCallDetail(label: "Lyrics", value: "[Instrumental]"),
            ToolCallDetail(label: "Duration", value: "30"),
            ToolCallDetail(label: "Instrumental", value: "true")
        ])
        XCTAssertEqual(plan.model.modelId, musicProfile.modelId)
        XCTAssertEqual(plan.loadingStatus, "Generating music...")
        XCTAssertEqual(plan.operationName, "Music generation")
        XCTAssertEqual(plan.unavailablePrefix, "Music generation unavailable")
        XCTAssertEqual(plan.noOutputMessage, "Music generation finished without returning audio.")
        XCTAssertTrue(plan.completionHint.contains("Do not include local file paths"))
        XCTAssertEqual(plan.attachmentKind, .audio)

        let request = plan.request
        XCTAssertEqual(request.backend, .music)
        XCTAssertEqual(request.modelId, musicProfile.modelId)
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(request.messages.first?.role, .user)
        XCTAssertEqual(request.messages.first?.content, "Night drive")
        XCTAssertNil(request.images)
        XCTAssertEqual(request.outputDirectory, outputDirectory)
        XCTAssertEqual(request.maxTokens, 0)
        XCTAssertEqual(request.temperature, 1.0)

        let requestParameters = try XCTUnwrap(request.parameters)
        XCTAssertEqual(requestParameters["seed"] as? Int, 0)
        XCTAssertEqual(requestParameters["caption"] as? String, "Night drive")
        XCTAssertEqual(requestParameters["lyrics"] as? String, "[Instrumental]")
    }

    private func makeProfile(
        id: String,
        name: String,
        modelId: String,
        modality: ModelModality,
        backend: RuntimeBackend
    ) -> ModelCapabilityProfile {
        ModelCapabilityProfile(
            id: id,
            name: name,
            subtitle: "Test",
            modelId: modelId,
            modality: modality,
            backend: backend,
            icon: "testtube.2",
            downloadSizeGB: 1,
            estimatedMemoryGB: 1,
            parameters: [],
            presets: []
        )
    }
}
