import Foundation

struct Chat: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var messages: [Message]
    var timestamp: Date
    var icon: String

    init(
        id: UUID = UUID(),
        title: String,
        messages: [Message],
        timestamp: Date,
        icon: String
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.timestamp = timestamp
        self.icon = icon
    }
    
    static func == (lhs: Chat, rhs: Chat) -> Bool {
        lhs.id == rhs.id
    }
}

enum ChatDisplayText {
    static func singleLine(
        _ text: String,
        fallback: String = "",
        maxLength: Int? = nil
    ) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let resolved = collapsed.isEmpty ? fallback : collapsed

        guard let maxLength, resolved.count > maxLength else {
            return resolved
        }

        let prefix = String(resolved.prefix(maxLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let lastSpaceIndex = prefix.lastIndex(where: { $0.isWhitespace }) {
            let wordSafePrefix = prefix[..<lastSpaceIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !wordSafePrefix.isEmpty {
                return String(wordSafePrefix)
            }
        }

        return prefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct Message: Identifiable, Codable {
    let id: UUID
    var content: String
    var isUser: Bool
    var timestamp: Date
    var toolCalls: [ToolCall]
    var isStreaming: Bool
    var imageURLs: [URL]
    var audioURLs: [URL]
    var performanceMetrics: GenerationPerformanceMetrics?
    
    init(
        id: UUID = UUID(),
        content: String,
        isUser: Bool,
        timestamp: Date,
        toolCall: ToolCall? = nil,
        isStreaming: Bool = false,
        imageURLs: [URL] = [],
        audioURLs: [URL] = [],
        performanceMetrics: GenerationPerformanceMetrics? = nil
    ) {
        self.id = id
        self.content = content
        self.isUser = isUser
        self.timestamp = timestamp
        self.toolCalls = toolCall.map { [$0] } ?? []
        self.isStreaming = isStreaming
        self.imageURLs = imageURLs
        self.audioURLs = audioURLs
        self.performanceMetrics = performanceMetrics
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case content
        case isUser
        case timestamp
        case toolCall
        case toolCalls
        case isStreaming
        case imageURLs
        case audioURLs
        case performanceMetrics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        isUser = try container.decode(Bool.self, forKey: .isUser)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isStreaming = try container.decode(Bool.self, forKey: .isStreaming)
        imageURLs = try container.decodeIfPresent([URL].self, forKey: .imageURLs) ?? []
        audioURLs = try container.decodeIfPresent([URL].self, forKey: .audioURLs) ?? []
        performanceMetrics = try container.decodeIfPresent(GenerationPerformanceMetrics.self, forKey: .performanceMetrics)

        if let decodedToolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls) {
            toolCalls = decodedToolCalls
        } else if let decodedToolCall = try container.decodeIfPresent(ToolCall.self, forKey: .toolCall) {
            toolCalls = [decodedToolCall]
        } else {
            toolCalls = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(isUser, forKey: .isUser)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(toolCalls, forKey: .toolCalls)
        try container.encode(isStreaming, forKey: .isStreaming)
        try container.encode(imageURLs, forKey: .imageURLs)
        try container.encode(audioURLs, forKey: .audioURLs)
        try container.encodeIfPresent(performanceMetrics, forKey: .performanceMetrics)
    }
}

struct GenerationPerformanceMetrics: Codable, Equatable {
    var timeToFirstToken: TimeInterval?
    var tokensPerSecond: Double?
    var outputTokenCount: Int
    var totalDuration: TimeInterval
    var measuredAt: Date

    init(
        timeToFirstToken: TimeInterval? = nil,
        tokensPerSecond: Double? = nil,
        outputTokenCount: Int = 0,
        totalDuration: TimeInterval,
        measuredAt: Date = Date()
    ) {
        self.timeToFirstToken = timeToFirstToken
        self.tokensPerSecond = tokensPerSecond
        self.outputTokenCount = outputTokenCount
        self.totalDuration = totalDuration
        self.measuredAt = measuredAt
    }

    static func measured(
        startedAt: Date,
        firstOutputAt: Date?,
        completedAt: Date = Date(),
        outputTokenCount: Int,
        backendTokensPerSecond: Double? = nil
    ) -> GenerationPerformanceMetrics {
        let totalDuration = max(completedAt.timeIntervalSince(startedAt), 0)
        let timeToFirstToken = firstOutputAt.map { max($0.timeIntervalSince(startedAt), 0) }
        let tokenDuration = firstOutputAt.map { max(completedAt.timeIntervalSince($0), 0.001) } ?? max(totalDuration, 0.001)
        let appMeasuredTokensPerSecond = outputTokenCount > 0 ? Double(outputTokenCount) / tokenDuration : nil
        let bridgeTokensPerSecond = backendTokensPerSecond.flatMap { value in
            value.isFinite && value > 0 ? value : nil
        }
        let tokensPerSecond = bridgeTokensPerSecond ?? appMeasuredTokensPerSecond

        return GenerationPerformanceMetrics(
            timeToFirstToken: timeToFirstToken,
            tokensPerSecond: tokensPerSecond,
            outputTokenCount: outputTokenCount,
            totalDuration: totalDuration,
            measuredAt: completedAt
        )
    }
}

struct ToolCallDetail: Codable, Equatable {
    var label: String
    var value: String
}

struct ToolCall: Identifiable, Codable {
    let id: UUID
    var toolName: String
    var status: String
    var icon: String
    var details: [ToolCallDetail]

    enum CodingKeys: String, CodingKey {
        case id
        case toolName
        case status
        case icon
        case details
    }

    init(
        id: UUID = UUID(),
        toolName: String,
        status: String,
        icon: String,
        details: [ToolCallDetail] = []
    ) {
        self.id = id
        self.toolName = toolName
        self.status = status
        self.icon = icon
        self.details = details
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        toolName = try container.decode(String.self, forKey: .toolName)
        status = try container.decode(String.self, forKey: .status)
        icon = try container.decode(String.self, forKey: .icon)
        details = try container.decodeIfPresent([ToolCallDetail].self, forKey: .details) ?? []
    }
}
