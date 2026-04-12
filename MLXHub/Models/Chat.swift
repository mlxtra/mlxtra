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
    var toolCall: ToolCall?
    var isStreaming: Bool
    var imageURLs: [URL]
    
    init(
        id: UUID = UUID(),
        content: String,
        isUser: Bool,
        timestamp: Date,
        toolCall: ToolCall? = nil,
        isStreaming: Bool = false,
        imageURLs: [URL] = []
    ) {
        self.id = id
        self.content = content
        self.isUser = isUser
        self.timestamp = timestamp
        self.toolCall = toolCall
        self.isStreaming = isStreaming
        self.imageURLs = imageURLs
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
