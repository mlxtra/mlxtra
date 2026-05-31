import XCTest
@testable import MLXtra

final class ChatMediaToolPlanBuilderTests: XCTestCase {
    func testImagePlanUsesDecodedPromptAndPreservesMediaRequestSettings() throws {
        let imageProfile = makeProfile(
            id: "image",
            name: "Image Model",
            modelId: "black-forest-labs/FLUX.2-klein-4B",
            modality: .image,
            backend: .image,
            runtimeOptions: ModelRuntimeOptions(
                mflux: MFluxRuntimeOptions(
                    config: "dev",
                    textToImageClass: "FluxImagePipeline",
                    editClass: "FluxEditPipeline",
                    quantize: 4
                )
            )
        )
        let imageURL = URL(fileURLWithPath: "/tmp/reference.png")
        let outputDirectory = URL(fileURLWithPath: "/tmp/images")
        let generation = makeGenerationRequest(
            tool: .image,
            prompt: "fallback prompt",
            images: [imageURL],
            profiles: [.image: imageProfile],
            parametersByModelId: [
                imageProfile.modelId: ["seed": 0]
            ]
        )

        let plan = ChatMediaToolPlanBuilder.makeImagePlan(
            decodedArguments: ["prompt": "A precise studio product shot"],
            fallbackPrompt: generation.prompt,
            images: generation.images,
            generation: generation,
            outputDirectory: outputDirectory
        )

        XCTAssertEqual(plan.functionName, "generate_image")
        XCTAssertEqual(plan.toolName, "Image generation")
        XCTAssertEqual(plan.status, "A precise studio product shot")
        XCTAssertEqual(plan.icon, "photo")
        XCTAssertEqual(plan.model.modelId, imageProfile.modelId)
        XCTAssertEqual(plan.loadingStatus, "Generating image...")
        XCTAssertEqual(plan.operationName, "Image generation")
        XCTAssertEqual(plan.unavailablePrefix, "Image generation unavailable")
        XCTAssertEqual(plan.noOutputMessage, "Image generation finished without returning an image.")
        XCTAssertTrue(plan.completionHint.contains("Do not include markdown image syntax"))
        XCTAssertEqual(plan.attachmentKind, .image)

        let request = plan.request
        XCTAssertEqual(request.backend, .image)
        XCTAssertEqual(request.modelId, imageProfile.modelId)
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(request.messages.first?.role, .user)
        XCTAssertEqual(request.messages.first?.content, "A precise studio product shot")
        XCTAssertEqual(request.images, [imageURL])
        XCTAssertEqual(request.outputDirectory, outputDirectory)
        XCTAssertEqual(request.maxTokens, 0)
        XCTAssertEqual(request.temperature, 1.0)

        let parameters = try XCTUnwrap(request.parameters)
        XCTAssertEqual(parameters["seed"] as? Int, 0)
        let runtimeOptions = try XCTUnwrap(parameters["runtimeOptions"] as? [String: Any])
        let mflux = try XCTUnwrap(runtimeOptions["mflux"] as? [String: Any])
        XCTAssertEqual(mflux["config"] as? String, "dev")
        XCTAssertEqual(mflux["quantize"] as? Int, 4)
    }

    func testImagePlanFallsBackForBlankDecodedPromptAndOmitsEmptyImages() {
        let imageProfile = makeProfile(
            id: "image",
            name: "Image Model",
            modelId: "black-forest-labs/FLUX.2-klein-4B",
            modality: .image,
            backend: .image
        )
        let generation = makeGenerationRequest(
            tool: .image,
            prompt: "fallback prompt",
            profiles: [.image: imageProfile]
        )

        let plan = ChatMediaToolPlanBuilder.makeImagePlan(
            decodedArguments: ["prompt": " \n "],
            fallbackPrompt: generation.prompt,
            images: [],
            generation: generation,
            outputDirectory: URL(fileURLWithPath: "/tmp/images")
        )

        XCTAssertEqual(plan.status, "fallback prompt")
        XCTAssertEqual(plan.request.messages.first?.content, "fallback prompt")
        XCTAssertNil(plan.request.images)
    }

    func testSpeechPlanUsesDecodedTextAndPreservesAudioRuntimeOptions() throws {
        let speechProfile = makeProfile(
            id: "speech",
            name: "Speech Model",
            modelId: "mlx-community/Kokoro-82M-bf16",
            modality: .audio,
            backend: .audio,
            runtimeOptions: ModelRuntimeOptions(
                audio: AudioRuntimeOptions(
                    adapter: "mlx-audio",
                    defaultVoice: "af_heart",
                    languageByVoicePrefix: ["af_": "en-us"]
                )
            )
        )
        let outputDirectory = URL(fileURLWithPath: "/tmp/speech")
        let generation = makeGenerationRequest(
            tool: .tts,
            prompt: "fallback narration",
            profiles: [.audio: speechProfile],
            parametersByModelId: [
                speechProfile.modelId: ["voice": "af_heart", "seed": 0]
            ]
        )

        let plan = ChatMediaToolPlanBuilder.makeSpeechPlan(
            decodedArguments: ["text": "Read this script aloud"],
            fallbackPrompt: generation.prompt,
            generation: generation,
            outputDirectory: outputDirectory
        )

        XCTAssertEqual(plan.functionName, "create_speech")
        XCTAssertEqual(plan.toolName, "Speech generation")
        XCTAssertEqual(plan.status, "Read this script aloud")
        XCTAssertEqual(plan.icon, "waveform")
        XCTAssertEqual(plan.model.modelId, speechProfile.modelId)
        XCTAssertEqual(plan.loadingStatus, "Generating speech...")
        XCTAssertEqual(plan.operationName, "Speech generation")
        XCTAssertEqual(plan.unavailablePrefix, "Speech generation unavailable")
        XCTAssertEqual(plan.noOutputMessage, "Speech generation finished without returning audio.")
        XCTAssertTrue(plan.completionHint.contains("Do not include local file paths"))
        XCTAssertEqual(plan.attachmentKind, .audio)

        let request = plan.request
        XCTAssertEqual(request.backend, .audio)
        XCTAssertEqual(request.modelId, speechProfile.modelId)
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(request.messages.first?.role, .user)
        XCTAssertEqual(request.messages.first?.content, "Read this script aloud")
        XCTAssertNil(request.images)
        XCTAssertEqual(request.outputDirectory, outputDirectory)
        XCTAssertEqual(request.maxTokens, 0)
        XCTAssertEqual(request.temperature, 1.0)

        let parameters = try XCTUnwrap(request.parameters)
        XCTAssertEqual(parameters["voice"] as? String, "af_heart")
        XCTAssertEqual(parameters["seed"] as? Int, 0)
        let runtimeOptions = try XCTUnwrap(parameters["runtimeOptions"] as? [String: Any])
        let audio = try XCTUnwrap(runtimeOptions["audio"] as? [String: Any])
        XCTAssertEqual(audio["adapter"] as? String, "mlx-audio")
        XCTAssertEqual(audio["defaultVoice"] as? String, "af_heart")
        XCTAssertEqual(audio["languageByVoicePrefix"] as? [String: String], ["af_": "en-us"])
    }

    func testSpeechPlanFallsBackForBlankDecodedText() {
        let speechProfile = makeProfile(
            id: "speech",
            name: "Speech Model",
            modelId: "mlx-community/Kokoro-82M-bf16",
            modality: .audio,
            backend: .audio
        )
        let generation = makeGenerationRequest(
            tool: .tts,
            prompt: "fallback narration",
            profiles: [.audio: speechProfile]
        )

        let plan = ChatMediaToolPlanBuilder.makeSpeechPlan(
            decodedArguments: ["text": "\t"],
            fallbackPrompt: generation.prompt,
            generation: generation,
            outputDirectory: URL(fileURLWithPath: "/tmp/speech")
        )

        XCTAssertEqual(plan.status, "fallback narration")
        XCTAssertEqual(plan.request.messages.first?.content, "fallback narration")
    }

    private func makeGenerationRequest(
        tool: Tool,
        prompt: String,
        images: [URL] = [],
        profiles: [ModelModality: ModelCapabilityProfile],
        parametersByModelId: [String: [String: Any]] = [:]
    ) -> ChatGenerationRequest {
        ChatGenerationRequest(
            chatId: UUID(),
            prompt: prompt,
            images: images,
            tool: tool,
            profilesByModality: profiles,
            parametersByModelId: parametersByModelId,
            selectionDownloadRequirement: nil,
            selectionOperationName: "Test"
        )
    }

    private func makeProfile(
        id: String,
        name: String,
        modelId: String,
        modality: ModelModality,
        backend: RuntimeBackend,
        runtimeOptions: ModelRuntimeOptions? = nil
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
            runtimeOptions: runtimeOptions,
            parameters: [],
            presets: []
        )
    }
}
