import SwiftUI

@main
struct MLXHubApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: makeLaunchViewModel())
        }
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)
        .windowStyle(.titleBar)
        .commands {
            MLXHubCommands()
        }

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

struct ChatCommandActions {
    let newChat: () -> Void
    let stopGeneration: () -> Void
    let focusComposer: () -> Void
    let canStopGeneration: Bool
    let canFocusComposer: Bool
}

private struct ChatCommandActionsKey: FocusedValueKey {
    typealias Value = ChatCommandActions
}

extension FocusedValues {
    var chatCommandActions: ChatCommandActions? {
        get { self[ChatCommandActionsKey.self] }
        set { self[ChatCommandActionsKey.self] = newValue }
    }
}

private struct MLXHubCommands: Commands {
    @FocusedValue(\.chatCommandActions) private var chatActions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                chatActions?.newChat()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(chatActions == nil)
        }

        CommandMenu("Chat") {
            Button("Stop Generation") {
                chatActions?.stopGeneration()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(chatActions?.canStopGeneration != true)

            Button("Focus Composer") {
                chatActions?.focusComposer()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(chatActions?.canFocusComposer != true)
        }
    }
}
