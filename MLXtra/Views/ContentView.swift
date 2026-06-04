import SwiftUI
#if DEBUG
import AppKit
#endif

struct ContentView: View {
    @ObservedObject private var viewModel: ChatViewModel
    @StateObject private var runtimeUpdateManager = RuntimeUpdateManager.shared
    @StateObject private var downloadManager = ModelDownloadManager.shared
    @State private var columnVisibility: NavigationSplitViewVisibility
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PromptConfiguration.hasSeenFirstRunGuideKey) private var hasSeenFirstRunGuide = false
    @AppStorage("MLXtra.pendingDownloadModelId") private var pendingDownloadModelId = ""
    @AppStorage(ChatViewModel.launchModelPreloadEnabledKey) private var preloadLocalChatModelOnLaunch = true

    init(viewModel: ChatViewModel = ChatViewModel()) {
        self.viewModel = viewModel
        _columnVisibility = State(initialValue: Self.initialColumnVisibility)
    }

    private var windowTitle: String {
        guard let chat = viewModel.selectedChat else {
            return "Chats"
        }

        return ChatDisplayText.singleLine(
            chat.title,
            fallback: "Untitled",
            maxLength: MLXtraDesignSystem.TextLimit.windowTitle
        )
    }

    private var chatCommandActions: ChatCommandActions {
        ChatCommandActions(
            newChat: viewModel.createNewChat,
            stopGeneration: viewModel.cancelGeneration,
            focusComposer: viewModel.focusComposer,
            canStopGeneration: viewModel.isGenerating,
            canFocusComposer: !viewModel.isInputDisabled
        )
    }

    var body: some View {
        GeometryReader { proxy in
            content(sidebarColumn: sidebarColumnMetrics(for: proxy.size.width))
        }
        .navigationTitle(shouldShowFirstRunExperience ? "MLXtra" : windowTitle)
        .focusedSceneValue(\.chatCommandActions, chatCommandActions)
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
            scheduleLaunchModelPreloadIfNeeded()
            startPendingModelDownloadIfReady()
        }
        .onChange(of: pendingDownloadModelId) { _, _ in
            startPendingModelDownloadIfReady()
        }
        .onChange(of: runtimeUpdateManager.state) { _, _ in
            startPendingModelDownloadIfReady()
        }
        .onChange(of: downloadManager.states) { _, _ in
            startPendingModelDownloadIfReady()
            scheduleLaunchModelPreloadIfNeeded()
        }
        .onChange(of: preloadLocalChatModelOnLaunch) { _, isEnabled in
            guard isEnabled else { return }
            scheduleLaunchModelPreloadIfNeeded(delayNanoseconds: 0)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.refreshLocalEngineDownloadStatus()
                startPendingModelDownloadIfReady()
                scheduleLaunchModelPreloadIfNeeded()
            }
        }
    }

    @ViewBuilder
    private func content(sidebarColumn: SidebarColumnMetrics) -> some View {
        if shouldShowFirstRunExperience {
            FirstRunExperienceView(
                runtimeUpdateManager: runtimeUpdateManager,
                starterModels: FirstRunStarterModel.recommended(),
                onOpenModel: openModelSetup,
                onOpenModels: openActiveModelSetup,
                onContinue: {
                    hasSeenFirstRunGuide = true
                    scheduleLaunchModelPreloadIfNeeded(delayNanoseconds: 0)
                }
            )
        } else {
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
                                        .font(.system(size: MLXtraDesignSystem.Icon.large, weight: .regular))
                                        .foregroundStyle(.secondary)
                                        .frame(
                                            width: MLXtraDesignSystem.Icon.toolbarButton,
                                            height: MLXtraDesignSystem.Icon.toolbarButton
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("New chat")
                                .accessibilityLabel("New chat")
                                .accessibilityIdentifier("toolbar.newChat")
                            }
                        }
                    }
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private var shouldShowFirstRunExperience: Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["MLXTRA_UI_TEST_MODE"] == "1" {
            return false
        }
#endif
        return !hasSeenFirstRunGuide
    }

    private func openActiveModelSetup() {
        pendingDownloadModelId = viewModel.activeModelProfile.modelId
        openSettings()
    }

    private func openModelSetup(_ model: DownloadableModel) {
        pendingDownloadModelId = model.modelId
        openSettings()
    }

    private func startPendingModelDownloadIfReady() {
        guard !pendingDownloadModelId.isEmpty else { return }
        guard let model = DownloadableModel.embeddedModel(modelId: pendingDownloadModelId) else {
            return
        }

        switch downloadManager.state(for: model) {
        case .downloaded:
            pendingDownloadModelId = ""
        case .notDownloaded, .failed:
            guard !model.requiresRuntimeSetupBeforeDownload() else {
                runtimeUpdateManager.bootstrapStableRuntimeInBackground(
                    reportFailures: true,
                    component: model.runtime.component
                )
                return
            }
            downloadManager.download(model)
        case .downloading, .paused:
            return
        }
    }

    private func scheduleLaunchModelPreloadIfNeeded(
        delayNanoseconds: UInt64 = ChatViewModel.defaultLaunchModelPreloadDelayNanoseconds
    ) {
#if DEBUG
        guard ProcessInfo.processInfo.environment["MLXTRA_UI_TEST_MODE"] != "1" else {
            return
        }
#endif
        viewModel.scheduleLaunchModelPreload(delayNanoseconds: delayNanoseconds)
    }

    private func sidebarColumnMetrics(for windowWidth: CGFloat) -> SidebarColumnMetrics {
        if windowWidth <= MLXtraDesignSystem.Layout.compactSidebarBreakpoint {
            return SidebarColumnMetrics(
                minWidth: MLXtraDesignSystem.Layout.sidebarMinWidth,
                idealWidth: MLXtraDesignSystem.Layout.sidebarCompactIdealWidth,
                maxWidth: MLXtraDesignSystem.Layout.sidebarCompactMaxWidth
            )
        }

        return SidebarColumnMetrics(
            minWidth: MLXtraDesignSystem.Layout.sidebarMinWidth,
            idealWidth: MLXtraDesignSystem.Layout.sidebarIdealWidth,
            maxWidth: MLXtraDesignSystem.Layout.sidebarMaxWidth
        )
    }

#if DEBUG
    private static var initialColumnVisibility: NavigationSplitViewVisibility {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MLXTRA_UI_TEST_MODE"] == "1",
              environment["MLXTRA_UI_TEST_HIDE_SIDEBAR"] == "1" else {
            return .all
        }

        return .detailOnly
    }

    private func applyUITestWindowSizeIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MLXTRA_UI_TEST_MODE"] == "1",
              let widthValue = environment["MLXTRA_UI_TEST_WINDOW_WIDTH"],
              let heightValue = environment["MLXTRA_UI_TEST_WINDOW_HEIGHT"],
              let width = Double(widthValue),
              let height = Double(heightValue) else {
            return
        }

        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first(where: { window in
                window.isVisible && window.title != "MLXtra Settings"
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
