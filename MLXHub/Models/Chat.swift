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

struct Message: Identifiable, Codable {
    let id: UUID
    var content: String
    var isUser: Bool
    var timestamp: Date
    var toolCalls: [ToolCall]
    var isStreaming: Bool
    var imageURLs: [URL]
    var audioURLs: [URL]
    
    init(
        id: UUID = UUID(),
        content: String,
        isUser: Bool,
        timestamp: Date,
        toolCall: ToolCall? = nil,
        isStreaming: Bool = false,
        imageURLs: [URL] = [],
        audioURLs: [URL] = []
    ) {
        self.id = id
        self.content = content
        self.isUser = isUser
        self.timestamp = timestamp
        self.toolCalls = toolCall.map { [$0] } ?? []
        self.isStreaming = isStreaming
        self.imageURLs = imageURLs
        self.audioURLs = audioURLs
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
    }
}

struct ToolCall: Identifiable, Codable {
    let id: UUID
    var toolName: String
    var status: String
    var icon: String

    init(
        id: UUID = UUID(),
        toolName: String,
        status: String,
        icon: String
    ) {
        self.id = id
        self.toolName = toolName
        self.status = status
        self.icon = icon
    }
}
