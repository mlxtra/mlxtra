import XCTest
@testable import MLXtra

final class ChatExecutionRequestBuilderTests: XCTestCase {
    func testChatRequestUsesMessagesSamplingImagesToolsAndTemplateKwargs() throws {
        let chatProfile = makeProfile(
            id: "chat",
            name: "Chat Model",
            modelId: "mlx-community/chat",
            modality: .vision,
            backend: .llm,
            defaultMaxTokens: 512,
            runtimeOptions: ModelRuntimeOptions(
                chatTemplate: ChatTemplateRuntimeOptions(parameterKwargs: [
                    "enable_thinking": "thinking_enabled"
                ])
            ),
            parameters: [
                ModelParameterDefinition(key: "temperature", label: "Temperature", type: .decimal, defaultValue: "0.4"),
                ModelParameterDefinition(key: "top_p", label: "Top P", type: .decimal, defaultValue: "0.9"),
                ModelParameterDefinition(key: "top_k", label: "Top K", type: .integer, defaultValue: "20"),
                ModelParameterDefinition(key: "min_p", label: "Min P", type: .decimal, defaultValue: "0.05"),
                ModelParameterDefinition(key: "repetition_penalty", label: "Penalty", type: .decimal, defaultValue: "1.1")
            ]
        )
        let generation = makeGenerationRequest(
            tool: .chat,
            prompt: "Summarize this",
            images: [URL(fileURLWithPath: "/tmp/reference.png")],
            profiles: [.vision: chatProfile],
            parametersByModelId: [
                chatProfile.modelId: [
                    "max_tokens": 123,
                    "temperature": 0.2,
                    "top_p": 0.8,
                    "top_k": 12,
                    "min_p": 0.1,
                    "repetition_penalty": 1.05,
                    "thinking_enabled": true
                ]
            ]
        )
        let messages = [
            ExecutionMessage(role: .system, content: "System"),
            ExecutionMessage(role: .user, content: "User")
        ]
        let tools: [[String: Any]] = [
            ["type": "function", "function": ["name": "web_search"]]
        ]

        let request = ChatExecutionRequestBuilder.makeRequest(
            generation: generation,
            activeChatProfile: chatProfile,
            executionProfile: chatProfile,
            messages: messages,
            tools: tools,
            outputDirectory: nil
        )

        XCTAssertEqual(request.backend, .llm)
        XCTAssertEqual(request.modelId, chatProfile.modelId)
        XCTAssertEqual(request.images?.map(\.path), ["/tmp/reference.png"])
        XCTAssertNil(request.outputDirectory)
        XCTAssertEqual(request.maxTokens, 123)
        XCTAssertEqual(request.temperature, 0.2)
        XCTAssertEqual(request.topP, 0.8)
        XCTAssertEqual(request.topK, 12)
        XCTAssertEqual(request.minP, 0.1)
        XCTAssertEqual(request.repetitionPenalty, 1.05)
        XCTAssertNil(request.parameters)

        XCTAssertEqual(request.messages.count, 2)
        XCTAssertEqual(request.messages[0].role, .system)
        XCTAssertEqual(request.messages[0].content, "System")
        XCTAssertEqual(request.messages[1].role, .user)
        XCTAssertEqual(request.messages[1].content, "User")

        let templateKwargs = try XCTUnwrap(request.chatTemplateKwargs)
        XCTAssertEqual(templateKwargs["enable_thinking"] as? Bool, true)

        let requestTools = try XCTUnwrap(request.tools)
        XCTAssertEqual(requestTools.count, 1)
        XCTAssertEqual(requestTools[0]["type"] as? String, "function")
    }

    func testImageRequestUsesDirectPromptAndMediaParameters() throws {
        let chatProfile = makeProfile(
            id: "chat",
            name: "Chat Model",
            modelId: "mlx-community/chat",
            modality: .vision,
            backend: .llm,
            defaultMaxTokens: 512
        )
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
        let generation = makeGenerationRequest(
            tool: .image,
            prompt: "A quiet studio",
            images: [URL(fileURLWithPath: "/tmp/reference.png")],
            profiles: [
                .vision: chatProfile,
                .image: imageProfile
            ],
            parametersByModelId: [
                imageProfile.modelId: ["seed": 0]
            ]
        )
        let outputDirectory = URL(fileURLWithPath: "/tmp/images")

        let request = ChatExecutionRequestBuilder.makeRequest(
            generation: generation,
            activeChatProfile: chatProfile,
            executionProfile: imageProfile,
            messages: [
                ExecutionMessage(role: .system, content: "Should not be used")
            ],
            tools: nil,
            outputDirectory: outputDirectory
        )

        XCTAssertEqual(request.backend, .image)
        XCTAssertEqual(request.modelId, imageProfile.modelId)
        XCTAssertEqual(request.images?.map(\.path), ["/tmp/reference.png"])
        XCTAssertEqual(request.outputDirectory, outputDirectory)
        XCTAssertEqual(request.maxTokens, 0)
        XCTAssertEqual(request.temperature, 1.0)
        XCTAssertNil(request.topP)
        XCTAssertNil(request.topK)
        XCTAssertNil(request.minP)
        XCTAssertNil(request.repetitionPenalty)
        XCTAssertNil(request.chatTemplateKwargs)
        XCTAssertNil(request.tools)

        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(request.messages.first?.role, .user)
        XCTAssertEqual(request.messages.first?.content, "A quiet studio")

        let parameters = try XCTUnwrap(request.parameters)
        XCTAssertEqual(parameters["seed"] as? Int, 0)
        let runtimeOptions = try XCTUnwrap(parameters["runtimeOptions"] as? [String: Any])
        let mflux = try XCTUnwrap(runtimeOptions["mflux"] as? [String: Any])
        XCTAssertEqual(mflux["config"] as? String, "dev")
        XCTAssertEqual(mflux["quantize"] as? Int, 4)
    }

    func testVLMRequestCombinesContextAndCurrentImages() {
        let chatProfile = makeProfile(
            id: "chat",
            name: "Chat Model",
            modelId: "mlx-community/chat",
            modality: .vision,
            backend: .vlm
        )
        let generation = makeGenerationRequest(
            tool: .chat,
            prompt: "Describe the follow-up",
            images: [
                URL(fileURLWithPath: "/tmp/current.png"),
                URL(fileURLWithPath: "/tmp/generated.png")
            ],
            profiles: [.vision: chatProfile]
        )

        let request = ChatExecutionRequestBuilder.makeRequest(
            generation: generation,
            activeChatProfile: chatProfile,
            executionProfile: chatProfile,
            messages: [ExecutionMessage(role: .user, content: "Describe the follow-up")],
            tools: nil,
            outputDirectory: nil,
            contextImages: [
                URL(fileURLWithPath: "/tmp/generated.png"),
                URL(fileURLWithPath: "/tmp/older.png")
            ]
        )

        XCTAssertEqual(
            request.images,
            [
                URL(fileURLWithPath: "/tmp/generated.png"),
                URL(fileURLWithPath: "/tmp/older.png"),
                URL(fileURLWithPath: "/tmp/current.png")
            ]
        )
    }

    func testDirectMediaRequestDoesNotUseContextImagesAsEditInputs() {
        let chatProfile = makeProfile(
            id: "chat",
            name: "Chat Model",
            modelId: "mlx-community/chat",
            modality: .vision,
            backend: .vlm
        )
        let imageProfile = makeProfile(
            id: "image",
            name: "Image Model",
            modelId: "black-forest-labs/FLUX.2-klein-4B",
            modality: .image,
            backend: .image
        )
        let generation = makeGenerationRequest(
            tool: .image,
            prompt: "Create a new poster",
            images: [URL(fileURLWithPath: "/tmp/current.png")],
            profiles: [
                .vision: chatProfile,
                .image: imageProfile
            ]
        )

        let request = ChatExecutionRequestBuilder.makeRequest(
            generation: generation,
            activeChatProfile: chatProfile,
            executionProfile: imageProfile,
            messages: [ExecutionMessage(role: .user, content: "Create a new poster")],
            tools: nil,
            outputDirectory: nil,
            contextImages: [URL(fileURLWithPath: "/tmp/generated.png")]
        )

        XCTAssertEqual(request.images, [URL(fileURLWithPath: "/tmp/current.png")])
    }

    func testToolEnabledVLMRequestKeepsContextImagesAsTextOnlyContext() {
        let chatProfile = makeProfile(
            id: "chat",
            name: "Chat Model",
            modelId: "mlx-community/chat",
            modality: .vision,
            backend: .vlm
        )
        let generation = makeGenerationRequest(
            tool: .auto,
            prompt: "Make it a movie poster",
            profiles: [.vision: chatProfile]
        )

        let request = ChatExecutionRequestBuilder.makeRequest(
            generation: generation,
            activeChatProfile: chatProfile,
            executionProfile: chatProfile,
            messages: [ExecutionMessage(role: .user, content: "Make it a movie poster")],
            tools: [["type": "function", "function": ["name": "generate_image"]]],
            outputDirectory: nil,
            contextImages: [URL(fileURLWithPath: "/tmp/generated.png")]
        )

        XCTAssertNil(request.images)
    }

    func testMusicToolChatRequestKeepsToolsButSkipsChatTemplateKwargs() throws {
        let chatProfile = makeProfile(
            id: "chat",
            name: "Chat Model",
            modelId: "mlx-community/chat",
            modality: .vision,
            backend: .llm,
            defaultMaxTokens: 256,
            runtimeOptions: ModelRuntimeOptions(
                chatTemplate: ChatTemplateRuntimeOptions(parameterKwargs: [
                    "enable_thinking": "thinking_enabled"
                ])
            )
        )
        let musicProfile = makeProfile(
            id: "music",
            name: "Music Model",
            modelId: "ACE-Step/acestep-v15-turbo-continuous",
            modality: .music,
            backend: .music
        )
        let generation = makeGenerationRequest(
            tool: .music,
            prompt: "Create a synthwave track",
            profiles: [
                .vision: chatProfile,
                .music: musicProfile
            ],
            parametersByModelId: [
                chatProfile.modelId: ["thinking_enabled": true]
            ]
        )
        let tools: [[String: Any]] = [
            ["type": "function", "function": ["name": "generate_music"]]
        ]
        let messages = [ExecutionMessage(role: .user, content: "Create a synthwave track")]

        let request = ChatExecutionRequestBuilder.makeRequest(
            generation: generation,
            activeChatProfile: chatProfile,
            executionProfile: chatProfile,
            messages: messages,
            tools: tools,
            outputDirectory: nil
        )

        XCTAssertEqual(request.backend, .llm)
        XCTAssertEqual(request.modelId, chatProfile.modelId)
        XCTAssertEqual(request.maxTokens, 256)
        XCTAssertEqual(request.messages.first?.content, "Create a synthwave track")
        XCTAssertNil(request.chatTemplateKwargs)
        XCTAssertNil(request.parameters)
        XCTAssertEqual(try XCTUnwrap(request.tools).count, 1)
        XCTAssertEqual(request.tools?.first?["type"] as? String, "function")
    }

    func testGenerationRequestFallsBackWhenProfileSnapshotIsMissingModality() {
        let generation = makeGenerationRequest(
            tool: .image,
            prompt: "Create an image",
            profiles: [:]
        )

        let profile = generation.profile(for: .image)

        XCTAssertEqual(profile.modality, .image)
        XCTAssertFalse(profile.modelId.isEmpty)
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
        defaultMaxTokens: Int = 0,
        runtimeOptions: ModelRuntimeOptions? = nil,
        parameters: [ModelParameterDefinition] = []
    ) -> ModelCapabilityProfile {
        ModelCapabilityProfile(
            id: id,
            name: name,
            subtitle: "Test",
            modelId: modelId,
            modality: modality,
            backend: backend,
            icon: "testtube.2",
            defaultMaxTokens: defaultMaxTokens,
            downloadSizeGB: 1,
            estimatedMemoryGB: 1,
            runtimeOptions: runtimeOptions,
            parameters: parameters,
            presets: []
        )
    }
}
