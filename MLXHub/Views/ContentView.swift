import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel: ChatViewModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("MLXHub.pendingDownloadModelId") private var pendingDownloadModelId = ""

    init(viewModel: ChatViewModel = ChatViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel)
        } detail: {
            MainContentView(viewModel: viewModel)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: viewModel.modelDownloadRequest) { _, requestedModel in
            guard let requestedModel else { return }
            pendingDownloadModelId = requestedModel.modelId
            openSettings()
            viewModel.clearModelDownloadRequest()
        }
        .onAppear {
            viewModel.refreshLocalEngineDownloadStatus()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.refreshLocalEngineDownloadStatus()
            }
        }
    }
}

#Preview {
    ContentView()
}
