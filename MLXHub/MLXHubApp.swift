import SwiftUI

@main
struct MLXHubApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: makeLaunchViewModel())
        }
        .defaultSize(width: 1200, height: 700)
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
        }
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
