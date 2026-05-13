import XCTest
@testable import MLXtra

final class LocalEngineStatusTests: XCTestCase {
    func testChatReadyUsesFriendlyModelName() {
        let status = LocalEngineStatus.resolve(
            runtimeState: .ready,
            isPythonLoading: false,
            isModelLoading: false,
            isGenerating: false,
            loadingMessage: "",
            isExecutorReady: true,
            isModelLoaded: true,
            selectedModelName: "Qwen 3.5",
            activeModelName: "Qwen 3.5",
            activeModelRole: .chat,
            pendingDownloadModelId: nil,
            pendingDownloadModelName: nil,
            freedModelName: nil,
            lastErrorMessage: nil
        )

        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.title, "Qwen is ready")
        XCTAssertEqual(status.detail, "Qwen 3.5 is using memory locally.")
        XCTAssertTrue(status.canFreeMemory)
        XCTAssertTrue(status.isVisibleInComposer)
    }

    func testImageLoadingUsesPlainLanguage() {
        let status = LocalEngineStatus.resolve(
            runtimeState: .ready,
            isPythonLoading: false,
            isModelLoading: true,
            isGenerating: false,
            loadingMessage: "Loading FLUX.2-klein-4B...",
            isExecutorReady: true,
            isModelLoaded: false,
            selectedModelName: "Qwen 3.5",
            activeModelName: "FLUX.2-klein-4B",
            activeModelRole: .image,
            pendingDownloadModelId: nil,
            pendingDownloadModelName: nil,
            freedModelName: nil,
            lastErrorMessage: nil
        )

        XCTAssertEqual(status.state, .loadingModel)
        XCTAssertEqual(status.title, "Loading image model")
        XCTAssertEqual(status.detail, "Loading FLUX.2-klein-4B...")
        XCTAssertFalse(status.canFreeMemory)
        XCTAssertTrue(status.isVisibleInComposer)
    }

    func testLoadingStateCarriesIndeterminateProgress() {
        let progress = ModelLoadProgress(
            modelId: "mlx-community/Qwen3.5-4B",
            backend: .vlm,
            phase: .loadingWeights,
            detail: "Loading model weights"
        )

        let status = LocalEngineStatus.resolve(
            runtimeState: .ready,
            isPythonLoading: false,
            isModelLoading: true,
            isGenerating: false,
            loadingMessage: "Loading Qwen...",
            loadProgress: progress,
            isExecutorReady: true,
            isModelLoaded: false,
            selectedModelName: "Qwen 3.5",
            activeModelName: "Qwen 3.5",
            activeModelRole: .chat,
            pendingDownloadModelId: nil,
            pendingDownloadModelName: nil,
            freedModelName: nil,
            lastErrorMessage: nil
        )

        XCTAssertEqual(status.state, .loadingModel)
        XCTAssertEqual(status.loadProgress, progress)
        XCTAssertNil(status.loadProgress?.fractionCompleted)
        XCTAssertEqual(status.detail, "Loading model weights")
    }

    func testBridgePercentIsClampedForDeterminateProgress() {
        let progress = ModelLoadProgress.bridgeEvent(
            [
                "type": "model.loading",
                "model": "mlx-community/Qwen3.5-4B",
                "backend": "vlm",
                "phase": "loading_weights",
                "percent": 125
            ],
            fallbackModelId: "fallback",
            fallbackBackend: .image
        )

        XCTAssertEqual(progress.modelId, "mlx-community/Qwen3.5-4B")
        XCTAssertEqual(progress.backend, .vlm)
        XCTAssertEqual(progress.phase, .loadingWeights)
        XCTAssertEqual(progress.fractionCompleted, 1.0)
    }

    func testBridgeFractionIsClampedForDeterminateProgress() {
        let progress = ModelLoadProgress.bridgeEvent(
            [
                "type": "model.loading",
                "status": "warming",
                "fraction": -0.2
            ],
            fallbackModelId: "fallback-model",
            fallbackBackend: .audio
        )

        XCTAssertEqual(progress.modelId, "fallback-model")
        XCTAssertEqual(progress.backend, .audio)
        XCTAssertEqual(progress.phase, .warming)
        XCTAssertEqual(progress.fractionCompleted, 0.0)
    }

    func testMusicReadyUsesModalityLabel() {
        let status = LocalEngineStatus.resolve(
            runtimeState: .ready,
            isPythonLoading: false,
            isModelLoading: false,
            isGenerating: false,
            loadingMessage: "",
            isExecutorReady: true,
            isModelLoaded: true,
            selectedModelName: "Qwen 3.5",
            activeModelName: "ACE-Step 1.5 Turbo",
            activeModelRole: .music,
            pendingDownloadModelId: nil,
            pendingDownloadModelName: nil,
            freedModelName: nil,
            lastErrorMessage: nil
        )

        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.title, "Music model is ready")
        XCTAssertEqual(status.detail, "ACE-Step 1.5 Turbo is using memory locally.")
    }

    func testIdleStateStaysOutOfComposer() {
        let status = LocalEngineStatus.resolve(
            runtimeState: .notInitialized,
            isPythonLoading: false,
            isModelLoading: false,
            isGenerating: false,
            loadingMessage: "",
            isExecutorReady: false,
            isModelLoaded: false,
            selectedModelName: "Qwen 3.5",
            activeModelName: nil,
            activeModelRole: .chat,
            pendingDownloadModelId: nil,
            pendingDownloadModelName: nil,
            freedModelName: nil,
            lastErrorMessage: nil
        )

        XCTAssertEqual(status.state, .idle)
        XCTAssertEqual(status.title, "Local model")
        XCTAssertFalse(status.isVisibleInComposer)
    }

    func testMemoryFreedTakesPrecedenceWhenExecutorIsUnloaded() {
        let status = LocalEngineStatus.resolve(
            runtimeState: .ready,
            isPythonLoading: false,
            isModelLoading: false,
            isGenerating: false,
            loadingMessage: "",
            isExecutorReady: false,
            isModelLoaded: false,
            selectedModelName: "Qwen 3.5",
            activeModelName: nil,
            activeModelRole: .chat,
            pendingDownloadModelId: nil,
            pendingDownloadModelName: nil,
            freedModelName: "Qwen 3.5",
            lastErrorMessage: nil
        )

        XCTAssertEqual(status.state, .memoryFreed)
        XCTAssertEqual(status.title, "Memory freed")
        XCTAssertEqual(status.detail, "Qwen 3.5 will load again when needed.")
        XCTAssertFalse(status.canFreeMemory)
    }

    func testPendingDownloadPointsToModelsAction() {
        let status = LocalEngineStatus.resolve(
            runtimeState: .ready,
            isPythonLoading: false,
            isModelLoading: false,
            isGenerating: false,
            loadingMessage: "",
            isExecutorReady: false,
            isModelLoaded: false,
            selectedModelName: "Qwen 3.5",
            activeModelName: nil,
            activeModelRole: .chat,
            pendingDownloadModelId: "ACE-Step/acestep-v15-turbo-continuous",
            pendingDownloadModelName: "ACE-Step 1.5 Turbo",
            freedModelName: nil,
            lastErrorMessage: nil
        )

        XCTAssertEqual(status.state, .needsDownload)
        XCTAssertEqual(status.title, "Needs download")
        XCTAssertEqual(status.primaryAction, .openModels)
        XCTAssertEqual(status.primaryActionModelId, "ACE-Step/acestep-v15-turbo-continuous")
        XCTAssertTrue(status.isVisibleInComposer)
    }

    func testRuntimeErrorUsesRestartAction() {
        let status = LocalEngineStatus.resolve(
            runtimeState: .error("Python failed"),
            isPythonLoading: false,
            isModelLoading: false,
            isGenerating: false,
            loadingMessage: "",
            isExecutorReady: false,
            isModelLoaded: false,
            selectedModelName: "Qwen 3.5",
            activeModelName: nil,
            activeModelRole: .chat,
            pendingDownloadModelId: nil,
            pendingDownloadModelName: nil,
            freedModelName: nil,
            lastErrorMessage: nil
        )

        XCTAssertEqual(status.state, .needsAttention)
        XCTAssertEqual(status.title, "Needs attention")
        XCTAssertEqual(status.detail, "The local engine stopped. Restart to continue.")
        XCTAssertEqual(status.primaryAction, .restart)
    }

    func testLastErrorMessageOverridesRuntimeErrorFallback() {
        let status = LocalEngineStatus.resolve(
            runtimeState: .error("Python failed"),
            isPythonLoading: false,
            isModelLoading: false,
            isGenerating: false,
            loadingMessage: "",
            isExecutorReady: false,
            isModelLoaded: false,
            selectedModelName: "Qwen 3.5",
            activeModelName: nil,
            activeModelRole: .chat,
            pendingDownloadModelId: nil,
            pendingDownloadModelName: nil,
            freedModelName: nil,
            lastErrorMessage: "  Bridge process exited  "
        )

        XCTAssertEqual(status.state, .needsAttention)
        XCTAssertEqual(status.detail, "Bridge process exited")
    }

    func testPreparingStatesUseProgressOrFallbackMessage() {
        let progress = ModelLoadProgress(
            modelId: "runtime",
            backend: .vlm,
            phase: .preparing,
            detail: "Extracting Python runtime"
        )

        for runtimeState in [RuntimeManager.RuntimeState.checkingBundle, .extractingBundle, .startingPython] {
            let status = LocalEngineStatus.resolve(
                runtimeState: runtimeState,
                isPythonLoading: false,
                isModelLoading: false,
                isGenerating: false,
                loadingMessage: "Starting",
                loadProgress: progress,
                isExecutorReady: false,
                isModelLoaded: false,
                selectedModelName: "Qwen 3.5",
                activeModelName: nil,
                activeModelRole: .chat,
                pendingDownloadModelId: nil,
                pendingDownloadModelName: nil,
                freedModelName: nil,
                lastErrorMessage: nil
            )

            XCTAssertEqual(status.state, .preparing)
            XCTAssertEqual(status.detail, "Extracting Python runtime")
            XCTAssertEqual(status.loadProgress, progress)
            XCTAssertEqual(status.systemImage, "bolt.horizontal.circle")
        }
    }

    func testGeneratingUsesRoleSpecificDefaultDetail() {
        let status = LocalEngineStatus.resolve(
            runtimeState: .ready,
            isPythonLoading: false,
            isModelLoading: false,
            isGenerating: true,
            loadingMessage: "  ",
            isExecutorReady: true,
            isModelLoaded: true,
            selectedModelName: "KugelAudio",
            activeModelName: "KugelAudio",
            activeModelRole: .speech,
            pendingDownloadModelId: nil,
            pendingDownloadModelName: nil,
            freedModelName: nil,
            lastErrorMessage: nil
        )

        XCTAssertEqual(status.state, .generating)
        XCTAssertEqual(status.title, "Generating...")
        XCTAssertEqual(status.detail, "Creating speech audio.")
        XCTAssertEqual(status.systemImage, "sparkles")
        XCTAssertFalse(status.canFreeMemory)
    }

    func testExecutorReadyButModelUnloadedStaysIdleUntilNeeded() {
        let status = LocalEngineStatus.resolve(
            runtimeState: .ready,
            isPythonLoading: false,
            isModelLoading: false,
            isGenerating: false,
            loadingMessage: "",
            isExecutorReady: true,
            isModelLoaded: false,
            selectedModelName: "Gemma 4",
            activeModelName: nil,
            activeModelRole: .chat,
            pendingDownloadModelId: nil,
            pendingDownloadModelName: nil,
            freedModelName: nil,
            lastErrorMessage: nil
        )

        XCTAssertEqual(status.state, .idle)
        XCTAssertEqual(status.title, "Ready to load")
        XCTAssertEqual(status.detail, "Gemma 4 will load when needed.")
        XCTAssertFalse(status.isVisibleInComposer)
    }

    func testModelRoleTitlesAndGeneratingDetailsCoverAllModalities() {
        XCTAssertEqual(LocalEngineModelRole.chat.loadingTitle(modelName: nil), "Loading Model")
        XCTAssertEqual(LocalEngineModelRole.chat.readyTitle(modelName: "Qwen 3.5"), "Qwen is ready")
        XCTAssertEqual(LocalEngineModelRole.chat.generatingDetail, "Writing a response.")

        XCTAssertEqual(LocalEngineModelRole.image.loadingTitle(modelName: "FLUX"), "Loading image model")
        XCTAssertEqual(LocalEngineModelRole.image.readyTitle(modelName: "FLUX"), "Image model is ready")
        XCTAssertEqual(LocalEngineModelRole.image.generatingDetail, "Creating an image.")

        XCTAssertEqual(LocalEngineModelRole.speech.loadingTitle(modelName: "KugelAudio"), "Loading speech model")
        XCTAssertEqual(LocalEngineModelRole.speech.readyTitle(modelName: "KugelAudio"), "Speech model is ready")
        XCTAssertEqual(LocalEngineModelRole.speech.generatingDetail, "Creating speech audio.")

        XCTAssertEqual(LocalEngineModelRole.music.loadingTitle(modelName: "ACE-Step"), "Loading music model")
        XCTAssertEqual(LocalEngineModelRole.music.readyTitle(modelName: "ACE-Step"), "Music model is ready")
        XCTAssertEqual(LocalEngineModelRole.music.generatingDetail, "Creating music.")
    }

    func testModelLoadPhaseAliasesAndDisplayTitles() {
        let cases: [(String?, ModelLoadProgress.Phase, String)] = [
            ("queued", .preparing, "Preparing runtime"),
            ("downloading", .loadingWeights, "Loading weights"),
            ("waiting-for-models", .initializing, "Initializing model"),
            ("warmup", .warming, "Warming model"),
            ("loaded", .ready, "Ready"),
            ("unexpected", .unknown, "Loading model"),
            (nil, .unknown, "Loading model")
        ]

        for (rawValue, expectedPhase, expectedTitle) in cases {
            let phase = ModelLoadProgress.Phase(bridgeValue: rawValue)
            XCTAssertEqual(phase, expectedPhase)
            XCTAssertEqual(phase.displayTitle, expectedTitle)
        }
    }

    func testModelLoadProgressBridgeEventParsesFallbacksAndNumberFormats() {
        let stringFraction = ModelLoadProgress.bridgeEvent(
            [
                "type": "model.loading",
                "status": "components_ready",
                "fraction_completed": "0.25",
                "message": "  Components ready  "
            ],
            fallbackModelId: "fallback",
            fallbackBackend: .music
        )

        XCTAssertEqual(stringFraction.modelId, "fallback")
        XCTAssertEqual(stringFraction.backend, .music)
        XCTAssertEqual(stringFraction.phase, .initializing)
        XCTAssertEqual(stringFraction.fractionCompleted, 0.25)
        XCTAssertEqual(stringFraction.detail, "Components ready")
        XCTAssertEqual(stringFraction.compactTitle(modelName: "ACE-Step 1.5"), "Initializing ACE-Step")

        let numericPercentage = ModelLoadProgress.bridgeEvent(
            [
                "type": "model.loading",
                "model": "kugelaudio/kugelaudio-0-open",
                "backend": "audio",
                "phase": "ready",
                "percentage": NSNumber(value: 42.0),
                "detail": ""
            ],
            fallbackModelId: "fallback",
            fallbackBackend: .vlm
        )

        XCTAssertEqual(numericPercentage.modelId, "kugelaudio/kugelaudio-0-open")
        XCTAssertEqual(numericPercentage.backend, .audio)
        XCTAssertEqual(numericPercentage.phase, .ready)
        XCTAssertEqual(numericPercentage.fractionCompleted, 0.42)
        XCTAssertNil(numericPercentage.detail)
        XCTAssertEqual(numericPercentage.compactTitle(modelName: "KugelAudio"), "Ready")
    }
}
