import Foundation

struct ChatExecutionMusicSystemContext {
    let intentState: MusicIntentState
    let composerInstruction: String?
}

enum ChatExecutionMessageBuilder {
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

        if let chat {
            messages.append(contentsOf: contextExecutionMessages(from: chat, excluding: assistantMessageId))
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

        if let musicContext {
            content += "\n\n\(musicContext.intentState.systemInstruction)"
            if let composerInstruction = musicContext.composerInstruction {
                content += "\n\n\(composerInstruction)"
            }
        }

        return content
    }

    private static func contextExecutionMessages(from chat: Chat, excluding excludedMessageId: UUID) -> [ExecutionMessage] {
        contextMessages(from: chat, excluding: excludedMessageId).map { message in
            ExecutionMessage(
                role: message.isUser ? .user : .assistant,
                content: message.content
            )
        }
    }

    private static func contextMessages(from chat: Chat, excluding excludedMessageId: UUID) -> [Message] {
        let completedMessages = chat.messages.filter { message in
            message.id != excludedMessageId && !message.isStreaming
        }

        return Array(completedMessages.suffix(20))
    }

    private static func toolAvailabilityInstruction(allowedToolNames: Set<String>) -> String {
        guard !allowedToolNames.isEmpty else {
            return "Available tools in this mode: none. Do not write, simulate, or mention tool calls."
        }

        let names = allowedToolNames.sorted().joined(separator: ", ")
        return "Available tools in this mode: \(names). Use only these tools. Do not call any other tool."
    }
}
