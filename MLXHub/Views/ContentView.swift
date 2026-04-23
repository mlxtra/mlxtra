import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()
    @Environment(\.openSettings) private var openSettings
    @AppStorage("MLXHub.pendingDownloadModelId") private var pendingDownloadModelId = ""

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
    }
}

#Preview {
    ContentView()
}
