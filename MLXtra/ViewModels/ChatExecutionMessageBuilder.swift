import Foundation

struct ChatExecutionMusicSystemContext {
    let intentState: MusicIntentState
    let composerInstruction: String?
}

struct ChatExecutionContext {
    let messages: [ExecutionMessage]
    let images: [URL]
}

enum ChatExecutionMessageBuilder {
    private static let maxContextImageCount = 4

    static func toolNames(from tools: [[String: Any]]?) -> Set<String> {
        guard let tools else { return [] }
        return Set(tools.compactMap { tool in
            guard let function = tool["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            return name
        })
    }

    static func makeInitialMessages(
        chat: Chat?,
        excluding assistantMessageId: UUID,
        baseSystemPrompt: String,
        allowedToolNames: Set<String>,
        musicContext: ChatExecutionMusicSystemContext?
    ) -> [ExecutionMessage] {
        makeInitialContext(
            chat: chat,
            excluding: assistantMessageId,
            baseSystemPrompt: baseSystemPrompt,
            allowedToolNames: allowedToolNames,
            musicContext: musicContext
        ).messages
    }

    static func makeInitialContext(
        chat: Chat?,
        excluding assistantMessageId: UUID,
        baseSystemPrompt: String,
        allowedToolNames: Set<String>,
        musicContext: ChatExecutionMusicSystemContext?
    ) -> ChatExecutionContext {
        var messages = [
            ExecutionMessage(
                role: .system,
                content: systemContent(
                    baseSystemPrompt: baseSystemPrompt,
                    allowedToolNames: allowedToolNames,
                    musicContext: musicContext
                )
            )
        ]

        var images: [URL] = []
        if let chat {
            let contextMessages = contextMessages(from: chat, excluding: assistantMessageId)
            messages.append(contentsOf: contextMessages.map(contextExecutionMessage))
            images = contextImages(from: contextMessages)
        }

        return ChatExecutionContext(messages: messages, images: images)
    }

    static func contextImages(chat: Chat?, excluding excludedMessageId: UUID) -> [URL] {
        guard let chat else { return [] }
        return contextImages(from: contextMessages(from: chat, excluding: excludedMessageId))
    }

    static func promptPreparationMessages(
        systemPrompt: String,
        contextMessages: [ExecutionMessage],
        sourcePrompt: String
    ) -> [ExecutionMessage] {
        var messages = [ExecutionMessage(role: .system, content: systemPrompt)]
        let trimmedSourcePrompt = sourcePrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        messages.append(contentsOf: contextMessages.compactMap { message in
            guard message.role != .system,
                  message.role != .tool,
                  message.toolCalls == nil,
                  let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else {
                return nil
            }

            return ExecutionMessage(role: message.role, content: content)
        })

        if !trimmedSourcePrompt.isEmpty,
           messages.last?.content?.trimmingCharacters(in: .whitespacesAndNewlines) != trimmedSourcePrompt {
            messages.append(ExecutionMessage(role: .user, content: trimmedSourcePrompt))
        }

        return messages
    }

    static func systemContent(
        baseSystemPrompt: String,
        allowedToolNames: Set<String>,
        musicContext: ChatExecutionMusicSystemContext?
    ) -> String {
        var content = baseSystemPrompt
        content += "\n\n\(toolAvailabilityInstruction(allowedToolNames: allowedToolNames))"

        if allowedToolNames.contains("generate_music") {
            content += "\n\n\(musicToolInstruction)"
        }

        if let musicContext {
            content += "\n\n\(musicContext.intentState.systemInstruction)"
            if let composerInstruction = musicContext.composerInstruction {
                content += "\n\n\(composerInstruction)"
            }
        }

        return content
    }

    private static func contextExecutionMessage(from message: Message) -> ExecutionMessage {
        ExecutionMessage(
            role: message.isUser ? .user : .assistant,
            content: contextContent(from: message)
        )
    }

    private static func contextMessages(from chat: Chat, excluding excludedMessageId: UUID) -> [Message] {
        let completedMessages = chat.messages.filter { message in
            message.id != excludedMessageId && !message.isStreaming
        }

        return Array(completedMessages.suffix(20))
    }

    private static func contextImages(from messages: [Message]) -> [URL] {
        var seen = Set<String>()
        let uniqueImages = messages.flatMap(\.imageURLs).filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
        return Array(uniqueImages.suffix(maxContextImageCount))
    }

    private static func contextContent(from message: Message) -> String {
        var parts: [String] = []
        let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContent.isEmpty {
            parts.append(trimmedContent)
        }

        let toolSummaries = message.toolCalls.compactMap(toolContextSummary)
        if !toolSummaries.isEmpty {
            parts.append(toolSummaries.joined(separator: "\n"))
        }

        if !message.imageURLs.isEmpty {
            let noun = message.imageURLs.count == 1 ? "image" : "images"
            let prefix = message.isUser ? "Attached" : "Generated"
            parts.append("\(prefix) \(message.imageURLs.count) \(noun) in this message.")
        }

        if !message.audioURLs.isEmpty {
            let noun = message.audioURLs.count == 1 ? "audio asset" : "audio assets"
            let prefix = message.isUser ? "Attached" : "Generated"
            parts.append("\(prefix) \(message.audioURLs.count) \(noun) in this message.")
        }

        if parts.isEmpty {
            return message.isUser ? "User message with no text." : "Assistant response with no text."
        }

        return parts.joined(separator: "\n\n")
    }

    private static func toolContextSummary(_ toolCall: ToolCall) -> String? {
        let title = toolCall.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = toolCall.status.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary: String?
        if !title.isEmpty && !status.isEmpty {
            summary = "\(title): \(status)"
        } else if !title.isEmpty {
            summary = title
        } else if !status.isEmpty {
            summary = status
        } else {
            summary = nil
        }

        let details = toolCall.displayDetails.compactMap { detail -> String? in
            let label = detail.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = detail.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !value.isEmpty else { return nil }
            return "\(label): \(value)"
        }

        let parts = [summary] + details
        let lines = parts.compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func toolAvailabilityInstruction(allowedToolNames: Set<String>) -> String {
        guard !allowedToolNames.isEmpty else {
            return "Available tools in this mode: none. Do not write, simulate, or mention tool calls."
        }

        let names = allowedToolNames.sorted().joined(separator: ", ")
        return "Available tools in this mode: \(names). Use only these tools. Do not call any other tool."
    }

    private static var musicToolInstruction: String {
        "Music rule: Do not write, invent, or draft lyrics unless the user explicitly asks you to write lyrics as a separate response. When calling generate_music, default to instrumental music unless the user has provided or approved exact lyrics. Never put newly written lyrics into generate_music."
    }
}
