import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel)
        } detail: {
            MainContentView(viewModel: viewModel)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: viewModel.modelDownloadRequest) { _, requestedModel in
            guard requestedModel != nil else { return }
            openSettings()
            viewModel.clearModelDownloadRequest()
        }
    }
}

#Preview {
    ContentView()
}
