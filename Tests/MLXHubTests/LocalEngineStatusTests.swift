import XCTest
@testable import MLXHub

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
            pendingDownloadModelName: nil,
            freedModelName: nil,
            lastErrorMessage: nil
        )

        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.title, "Qwen is ready")
        XCTAssertEqual(status.detail, "Qwen 3.5 is loaded locally.")
        XCTAssertTrue(status.canFreeMemory)
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
            pendingDownloadModelName: nil,
            freedModelName: nil,
            lastErrorMessage: nil
        )

        XCTAssertEqual(status.state, .loadingModel)
        XCTAssertEqual(status.title, "Loading image model")
        XCTAssertEqual(status.detail, "Loading FLUX.2-klein-4B...")
        XCTAssertFalse(status.canFreeMemory)
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
            pendingDownloadModelName: nil,
            freedModelName: nil,
            lastErrorMessage: nil
        )

        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.title, "Music model is ready")
        XCTAssertEqual(status.detail, "ACE-Step 1.5 Turbo is loaded locally.")
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
            pendingDownloadModelName: "ACE-Step 1.5 Turbo",
            freedModelName: nil,
            lastErrorMessage: nil
        )

        XCTAssertEqual(status.state, .needsDownload)
        XCTAssertEqual(status.title, "Needs download")
        XCTAssertEqual(status.primaryAction, .openModels)
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
            pendingDownloadModelName: nil,
            freedModelName: nil,
            lastErrorMessage: nil
        )

        XCTAssertEqual(status.state, .needsAttention)
        XCTAssertEqual(status.title, "Needs attention")
        XCTAssertEqual(status.detail, "The local engine stopped. Restart to continue.")
        XCTAssertEqual(status.primaryAction, .restart)
    }
}
