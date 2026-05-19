import AppKit
import SwiftUI

@main
struct MLXtraApp: App {
    @NSApplicationDelegateAdaptor(MLXtraApplicationDelegate.self) private var appDelegate
    @StateObject private var appState = MLXtraAppState()

    var body: some Scene {
        WindowGroup("MLXtra", id: "main") {
            ContentView(viewModel: appState.viewModel)
        }
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)
        .windowStyle(.titleBar)
        .commands {
            MLXtraCommands()
        }

        MenuBarExtra("MLXtra", image: "MLXtraMenuBarIcon") {
            QuickStudioView(viewModel: appState.viewModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }

    private var defaultWindowSize: CGSize {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["MLXTRA_UI_TEST_MODE"] == "1",
           let widthValue = environment["MLXTRA_UI_TEST_WINDOW_WIDTH"],
           let heightValue = environment["MLXTRA_UI_TEST_WINDOW_HEIGHT"],
           let width = Double(widthValue),
           let height = Double(heightValue) {
            return CGSize(width: width, height: height)
        }
#endif
        return CGSize(width: 1040, height: 660)
    }

}

@MainActor
private final class MLXtraAppState: ObservableObject {
    let viewModel: ChatViewModel

    init(viewModel: ChatViewModel = MLXtraAppState.makeLaunchViewModel()) {
        self.viewModel = viewModel
    }

    private static func makeLaunchViewModel() -> ChatViewModel {
#if DEBUG
        if ProcessInfo.processInfo.environment["MLXTRA_UI_TEST_MODE"] == "1" {
            return ChatViewModel.makeUITestViewModel()
        }
#endif
        return ChatViewModel()
    }
}

@MainActor
final class MLXtraApplicationDelegate: NSObject, NSApplicationDelegate {
    let appUpdateController = AppUpdateController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        bootstrapRuntimeIfNeeded()
    }

    var canCheckForUpdates: Bool {
        appUpdateController.canCheckForUpdates
    }

    func checkForUpdates() {
        appUpdateController.checkForUpdates()
    }

    private func bootstrapRuntimeIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MLXTRA_UI_TEST_MODE"] != "1",
              environment["MLXTRA_DISABLE_RUNTIME_BOOTSTRAP"] != "1" else {
            return
        }

        RuntimeUpdateManager.shared.bootstrapStableRuntimeInBackground(reportFailures: false)
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

private struct MLXtraCommands: Commands {
    @FocusedValue(\.chatCommandActions) private var chatActions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                chatActions?.newChat()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(chatActions == nil)
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates...") {
                NSApp.delegate.flatMap { $0 as? MLXtraApplicationDelegate }?.checkForUpdates()
            }
            .disabled(NSApp.delegate.flatMap { $0 as? MLXtraApplicationDelegate }?.canCheckForUpdates != true)
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
