import SwiftUI

@main
struct MLXHubApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: makeLaunchViewModel())
        }
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
        }
    }

    private var defaultWindowSize: CGSize {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["MLXHUB_UI_TEST_MODE"] == "1",
           let widthValue = environment["MLXHUB_UI_TEST_WINDOW_WIDTH"],
           let heightValue = environment["MLXHUB_UI_TEST_WINDOW_HEIGHT"],
           let width = Double(widthValue),
           let height = Double(heightValue) {
            return CGSize(width: width, height: height)
        }
#endif
        return CGSize(width: 1200, height: 700)
    }

    @MainActor
    private func makeLaunchViewModel() -> ChatViewModel {
#if DEBUG
        if ProcessInfo.processInfo.environment["MLXHUB_UI_TEST_MODE"] == "1" {
            return ChatViewModel.makeUITestViewModel()
        }
#endif
        return ChatViewModel()
    }
}
