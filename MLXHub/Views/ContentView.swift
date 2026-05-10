import SwiftUI
#if DEBUG
import AppKit
#endif

struct ContentView: View {
    @StateObject private var viewModel: ChatViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("MLXHub.pendingDownloadModelId") private var pendingDownloadModelId = ""

    init(viewModel: ChatViewModel = ChatViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _columnVisibility = State(initialValue: Self.initialColumnVisibility)
    }

    private var windowTitle: String {
        guard let chat = viewModel.selectedChat else {
            return "Chats"
        }

        return ChatDisplayText.singleLine(
            chat.title,
            fallback: "Untitled",
            maxLength: MLXHubDesignSystem.TextLimit.windowTitle
        )
    }

    var body: some View {
        GeometryReader { proxy in
            content(sidebarColumn: sidebarColumnMetrics(for: proxy.size.width))
        }
    }

    @ViewBuilder
    private func content(sidebarColumn: SidebarColumnMetrics) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(
                    min: sidebarColumn.minWidth,
                    ideal: sidebarColumn.idealWidth,
                    max: sidebarColumn.maxWidth
                )
        } detail: {
            MainContentView(viewModel: viewModel)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        if columnVisibility == .detailOnly {
                            Button(action: viewModel.createNewChat) {
                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: MLXHubDesignSystem.Icon.large, weight: .regular))
                                    .foregroundStyle(.secondary)
                                    .frame(
                                        width: MLXHubDesignSystem.Icon.toolbarButton,
                                        height: MLXHubDesignSystem.Icon.toolbarButton
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut("n", modifiers: .command)
                            .help("New chat")
                            .accessibilityLabel("New chat")
                            .accessibilityIdentifier("toolbar.newChat")
                        }
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(windowTitle)
        .onChange(of: viewModel.modelDownloadRequest) { _, requestedModel in
            guard let requestedModel else { return }
            pendingDownloadModelId = requestedModel.modelId
            openSettings()
            viewModel.clearModelDownloadRequest()
        }
        .onAppear {
#if DEBUG
            applyUITestWindowSizeIfNeeded()
#endif
            viewModel.refreshLocalEngineDownloadStatus()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.refreshLocalEngineDownloadStatus()
            }
        }
    }

    private func sidebarColumnMetrics(for windowWidth: CGFloat) -> SidebarColumnMetrics {
        if windowWidth <= MLXHubDesignSystem.Layout.compactSidebarBreakpoint {
            return SidebarColumnMetrics(
                minWidth: MLXHubDesignSystem.Layout.sidebarMinWidth,
                idealWidth: MLXHubDesignSystem.Layout.sidebarCompactIdealWidth,
                maxWidth: MLXHubDesignSystem.Layout.sidebarCompactMaxWidth
            )
        }

        return SidebarColumnMetrics(
            minWidth: MLXHubDesignSystem.Layout.sidebarMinWidth,
            idealWidth: MLXHubDesignSystem.Layout.sidebarIdealWidth,
            maxWidth: MLXHubDesignSystem.Layout.sidebarMaxWidth
        )
    }

#if DEBUG
    private static var initialColumnVisibility: NavigationSplitViewVisibility {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MLXHUB_UI_TEST_MODE"] == "1",
              environment["MLXHUB_UI_TEST_HIDE_SIDEBAR"] == "1" else {
            return .all
        }

        return .detailOnly
    }

    private func applyUITestWindowSizeIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MLXHUB_UI_TEST_MODE"] == "1",
              let widthValue = environment["MLXHUB_UI_TEST_WINDOW_WIDTH"],
              let heightValue = environment["MLXHUB_UI_TEST_WINDOW_HEIGHT"],
              let width = Double(widthValue),
              let height = Double(heightValue) else {
            return
        }

        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first(where: { window in
                window.isVisible && window.title != "MLXHub Settings"
            }) ?? NSApplication.shared.keyWindow else {
                return
            }

            let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let origin = CGPoint(
                x: screenFrame.midX - width / 2,
                y: screenFrame.midY - height / 2
            )
            window.setFrame(
                CGRect(origin: origin, size: CGSize(width: width, height: height)),
                display: true,
                animate: false
            )
        }
    }
#else
    private static var initialColumnVisibility: NavigationSplitViewVisibility {
        .all
    }
#endif
}

private struct SidebarColumnMetrics {
    let minWidth: CGFloat
    let idealWidth: CGFloat
    let maxWidth: CGFloat
}

#Preview {
    ContentView()
}
