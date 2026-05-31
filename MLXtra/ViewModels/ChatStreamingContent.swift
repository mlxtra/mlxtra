import Combine
import Foundation

@MainActor
final class StreamingMessageContent: ObservableObject, Identifiable {
    let id: UUID
    @Published private(set) var revision = 0
    private(set) var text: String
    private(set) var latestMutation: StreamingMessageContentMutation
    private(set) var containsReasoningMarkup: Bool

    init(id: UUID, text: String = "") {
        self.id = id
        self.text = text
        self.latestMutation = .replace(text)
        self.containsReasoningMarkup = Self.hasReasoningMarkup(text)
    }

    func update(_ text: String) {
        guard self.text != text else { return }
        self.text = text
        latestMutation = .replace(text)
        containsReasoningMarkup = Self.hasReasoningMarkup(text)
        revision &+= 1
    }

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        let detectionWindow = String(self.text.suffix(32)) + text
        self.text += text
        latestMutation = .append(text)
        containsReasoningMarkup = containsReasoningMarkup || Self.hasReasoningMarkup(detectionWindow)
        revision &+= 1
    }

    func clear() {
        update("")
    }

    private static func hasReasoningMarkup(_ text: String) -> Bool {
        text.contains("<think")
            || text.contains("</think")
            || text.contains("<thinking")
            || text.contains("</thinking")
    }
}

enum StreamingMessageContentMutation {
    case append(String)
    case replace(String)
}

struct ChatStreamPerformanceTracker {
    let startedAt: Date
    private(set) var firstOutputAt: Date?
    private(set) var observedTokenEvents = 0

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    mutating func recordTokenOutput(at date: Date = Date()) {
        recordFirstOutputIfNeeded(at: date)
        observedTokenEvents += 1
    }

    mutating func recordNonTokenOutput(at date: Date = Date()) {
        recordFirstOutputIfNeeded(at: date)
    }

    func appMeasuredMetrics(
        usage: TokenUsage,
        completedAt: Date = Date()
    ) -> GenerationPerformanceMetrics {
        GenerationPerformanceMetrics.measured(
            startedAt: startedAt,
            firstOutputAt: firstOutputAt,
            completedAt: completedAt,
            outputTokenCount: outputTokenCount(for: usage)
        )
    }

    func metrics(
        usage: TokenUsage,
        completedAt: Date = Date()
    ) -> GenerationPerformanceMetrics {
        GenerationPerformanceMetrics.measured(
            startedAt: startedAt,
            firstOutputAt: firstOutputAt,
            completedAt: completedAt,
            outputTokenCount: outputTokenCount(for: usage),
            backendTokensPerSecond: usage.tokensPerSecond
        )
    }

    private mutating func recordFirstOutputIfNeeded(at date: Date) {
        firstOutputAt = firstOutputAt ?? date
    }

    private func outputTokenCount(for usage: TokenUsage) -> Int {
        usage.completionTokens > 0 ? usage.completionTokens : observedTokenEvents
    }
}

@MainActor
final class StreamingMessageContentStore {
    private var entries: [UUID: StreamingMessageContent] = [:]

    func begin(messageId: UUID, initialText: String = "") -> StreamingMessageContent {
        if let existing = entries[messageId] {
            existing.update(initialText)
            return existing
        }

        let content = StreamingMessageContent(id: messageId, text: initialText)
        entries[messageId] = content
        return content
    }

    func content(for messageId: UUID) -> StreamingMessageContent? {
        entries[messageId]
    }

    func update(messageId: UUID, text: String) {
        if let existing = entries[messageId] {
            existing.update(text)
        } else {
            _ = begin(messageId: messageId, initialText: text)
        }
    }

    func append(messageId: UUID, text: String) {
        if let existing = entries[messageId] {
            existing.append(text)
        } else {
            _ = begin(messageId: messageId, initialText: text)
        }
    }

    func clear(messageId: UUID) {
        content(for: messageId)?.clear()
    }

    func end(messageId: UUID) {
        entries.removeValue(forKey: messageId)
    }
}
