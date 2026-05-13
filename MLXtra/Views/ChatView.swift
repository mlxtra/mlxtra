import AppKit
import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.openSettings) private var openSettings
    @State private var shouldAutoScrollToBottom = true
    let chatId: UUID

    private let bottomAnchorID = "chat-bottom-anchor"

    // Access chat through viewModel so updates are observed
    var chat: Chat? {
        viewModel.chats.first { $0.id == chatId }
    }

    private var streamingAssistantMessage: Message? {
        chat?.messages.last { !$0.isUser && $0.isStreaming }
    }

    private var streamingAssistantContent: StreamingMessageContent? {
        guard let streamingAssistantMessage else { return nil }
        return viewModel.streamingContent(for: streamingAssistantMessage.id)
    }

    private var hasStreamingProgressSurface: Bool {
        streamingAssistantMessage != nil
    }

    private var shouldShowTypingIndicator: Bool {
        viewModel.isGenerating
            && !hasStreamingProgressSurface
            && !viewModel.isPythonLoading
            && !viewModel.isModelLoading
    }

    private var latestMessageContent: String {
        chat?.messages.last?.content ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                transcriptScrollView
                    .overlay(alignment: .bottom) {
                        if let streamingAssistantContent {
                            StreamingTranscriptAutoScroll(
                                content: streamingAssistantContent,
                                isEnabled: $shouldAutoScrollToBottom
                            ) {
                                scrollToBottom(proxy)
                            }
                        }
                    }
                    .onAppear {
                        resumeAutoScrollAndScrollToBottom(proxy)
                    }
                    .onChange(of: chat?.messages.count) { _, _ in
                        resumeAutoScrollAndScrollToBottom(proxy)
                    }
                    .onChange(of: viewModel.isGenerating) { _, isGenerating in
                        if isGenerating {
                            resumeAutoScrollAndScrollToBottom(proxy)
                        } else {
                            scrollToBottomIfFollowing(proxy)
                        }
                    }
                    .onChange(of: latestMessageContent) { _, _ in
                        scrollToBottomIfFollowing(proxy)
                    }
            }
            .frame(maxHeight: .infinity)

            ComposerView(viewModel: viewModel)
                .frame(maxWidth: MLXtraDesignSystem.Layout.composerMaxWidth)
                .padding(.horizontal, MLXtraDesignSystem.Layout.chatHorizontalPadding)
                .padding(.bottom, MLXtraDesignSystem.Layout.floatingAccessoryBottomPadding)
        }
        .background(MLXtraDesignSystem.Palette.windowBackground)
    }

    @ViewBuilder
    private var transcriptScrollView: some View {
        let scrollView = ScrollView {
            LazyVStack(spacing: MLXtraDesignSystem.Spacing.xl) {
                ForEach(chat?.messages ?? []) { message in
                    MessageBubble(
                        message: message,
                        isStreaming: message.isStreaming,
                        streamingContent: viewModel.streamingContent(for: message.id),
                        onOpenModels: { openSettings() },
                        onRestartLocalEngine: viewModel.restartLocalEngine
                    )
                    .id(message.id)
                }

                if shouldShowTypingIndicator {
                    TypingIndicator()
                        .id(streamingAssistantMessage?.id)
                }

                Color.clear
                    .frame(height: MLXtraDesignSystem.Layout.composerTranscriptGap)
                    .id(bottomAnchorID)
            }
            .background(
                TranscriptScrollIntentObserver(isAutoScrollEnabled: $shouldAutoScrollToBottom)
            )
            .padding(.top, MLXtraDesignSystem.Layout.chatHorizontalPadding)
            .frame(maxWidth: MLXtraDesignSystem.Layout.transcriptMaxWidth, alignment: .leading)
            .padding(.horizontal, MLXtraDesignSystem.Layout.transcriptHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityIdentifier("chat.transcript")

        scrollView
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private func scrollToBottomIfFollowing(_ proxy: ScrollViewProxy) {
        guard shouldAutoScrollToBottom else { return }
        scrollToBottom(proxy)
    }

    private func resumeAutoScrollAndScrollToBottom(_ proxy: ScrollViewProxy) {
        shouldAutoScrollToBottom = true
        scrollToBottom(proxy)
    }
}

private struct StreamingTranscriptAutoScroll: View {
    @ObservedObject var content: StreamingMessageContent
    @Binding var isEnabled: Bool
    let onScroll: () -> Void
    @State private var pendingScroll = false
    @State private var lastScrollTime = Date.distantPast

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                scheduleScroll()
            }
            .onChange(of: content.revision) { _, _ in
                scheduleScroll()
            }
    }

    private func scheduleScroll() {
        guard !pendingScroll else { return }
        pendingScroll = true

        let minimumInterval: TimeInterval = 1.0 / 30.0
        let delay = max(0, minimumInterval - Date().timeIntervalSince(lastScrollTime))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            pendingScroll = false
            guard isEnabled else { return }
            lastScrollTime = Date()
            onScroll()
        }
    }
}

private struct TranscriptScrollIntentObserver: NSViewRepresentable {
    @Binding var isAutoScrollEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isAutoScrollEnabled: $isAutoScrollEnabled)
    }

    func makeNSView(context: Context) -> TranscriptScrollObserverView {
        let view = TranscriptScrollObserverView()
        view.onMoveToWindow = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.attachIfPossible(from: view)
        }
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }
            coordinator?.attachIfPossible(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: TranscriptScrollObserverView, context: Context) {
        context.coordinator.isAutoScrollEnabled = $isAutoScrollEnabled
        context.coordinator.attachIfPossible(from: nsView)
    }

    static func dismantleNSView(_ nsView: TranscriptScrollObserverView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var isAutoScrollEnabled: Binding<Bool>
        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var localScrollMonitor: Any?
        private var userScrollGeneration = 0
        private var isUserScrolling = false
        private let bottomThreshold: CGFloat = 36

        init(isAutoScrollEnabled: Binding<Bool>) {
            self.isAutoScrollEnabled = isAutoScrollEnabled
        }

        func attachIfPossible(from view: NSView) {
            guard let enclosingScrollView = view.enclosingScrollView,
                  enclosingScrollView !== scrollView else {
                return
            }

            detach()
            scrollView = enclosingScrollView
            enclosingScrollView.contentView.postsBoundsChangedNotifications = true

            let center = NotificationCenter.default
            observers.append(
                center.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: enclosingScrollView.contentView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateAutoScrollState()
                    }
                }
            )
            observers.append(
                center.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: enclosingScrollView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.beginUserScroll()
                    }
                }
            )
            observers.append(
                center.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification,
                    object: enclosingScrollView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.endUserScrollSoon()
                    }
                }
            )

            localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleScrollWheel(event)
                }
                return event
            }

            updateAutoScrollState()
        }

        func detach() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()

            if let localScrollMonitor {
                NSEvent.removeMonitor(localScrollMonitor)
                self.localScrollMonitor = nil
            }

            scrollView = nil
            isUserScrolling = false
        }

        private func handleScrollWheel(_ event: NSEvent) {
            guard let scrollView,
                  let window = scrollView.window,
                  event.window === window else {
                return
            }

            let pointInScrollView = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(pointInScrollView) else { return }

            beginUserScroll()
            endUserScrollSoon()
        }

        private func beginUserScroll() {
            userScrollGeneration += 1
            isUserScrolling = true
            updateAutoScrollState()
        }

        private func endUserScrollSoon() {
            let generation = userScrollGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.userScrollGeneration == generation else { return }
                self.isUserScrolling = false
                self.updateAutoScrollState()
            }
        }

        private func updateAutoScrollState() {
            guard let scrollView else { return }

            let documentHeight = scrollView.documentView?.bounds.height
                ?? scrollView.documentView?.frame.height
                ?? 0
            let visibleMaxY = scrollView.contentView.bounds.maxY
            let visibleHeight = scrollView.contentView.bounds.height
            let canScroll = documentHeight > visibleHeight + bottomThreshold
            let isNearBottom = !canScroll || documentHeight - visibleMaxY <= bottomThreshold

            if isNearBottom {
                isAutoScrollEnabled.wrappedValue = true
            } else if isUserScrolling {
                isAutoScrollEnabled.wrappedValue = false
            }
        }
    }
}

private final class TranscriptScrollObserverView: NSView {
    var onMoveToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(alignment: .top, spacing: MLXtraDesignSystem.Spacing.xl) {
            HStack(spacing: MLXtraDesignSystem.Spacing.md) {
                Text("Responding")
                    .font(MLXtraDesignSystem.Typography.compactBodyMedium)
                    .foregroundStyle(.secondary)

                HStack(spacing: MLXtraDesignSystem.Spacing.xs) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 5, height: 5)
                            .scaleEffect(animating ? 1.0 : 0.55)
                            .opacity(animating ? 1.0 : 0.45)
                            .animation(
                                .easeInOut(duration: 0.55)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.16),
                                value: animating
                            )
                    }
                }
            }
            .padding(.horizontal, MLXtraDesignSystem.Spacing.xl)
            .padding(.vertical, MLXtraDesignSystem.Spacing.md)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.media))
            .overlay(
                RoundedRectangle(cornerRadius: MLXtraDesignSystem.Radius.media)
                    .stroke(MLXtraDesignSystem.Surface.hairline, lineWidth: MLXtraDesignSystem.Spacing.hairline)
            )

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            animating = true
        }
    }
}

#Preview {
    let vm = ChatViewModel()
    if let chat = vm.selectedChat {
        ChatView(viewModel: vm, chatId: chat.id)
    } else {
        Text("No chat available")
    }
}
