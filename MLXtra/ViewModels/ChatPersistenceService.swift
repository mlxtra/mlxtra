@preconcurrency import Foundation

private final class UserDefaultsWriter: @unchecked Sendable {
    let userDefaults: UserDefaults

    init(_ userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }
}

private struct PendingChatSaveSnapshot: @unchecked Sendable {
    let chats: [Chat]
    let selectedChatId: UUID?
}

@MainActor
final class LocalChatPersistenceService: ChatPersistenceServicing {
    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let userDefaultsWriter: UserDefaultsWriter
    private let selectedChatKey: String
    private let storageDirectory: URL
    private let writeQueue = DispatchQueue(label: "com.localstudio.mlxtra.chat-persistence", qos: .utility)
    private var pendingSaveWorkItem: DispatchWorkItem?
    private var pendingSaveSnapshot: PendingChatSaveSnapshot?
    private let saveDebounceInterval: TimeInterval

    init(
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        storageDirectory: URL? = nil,
        selectedChatKey: String = "MLXtra.selectedChatId",
        saveDebounceInterval: TimeInterval = 1.0
    ) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.userDefaultsWriter = UserDefaultsWriter(userDefaults)
        self.selectedChatKey = selectedChatKey
        self.saveDebounceInterval = saveDebounceInterval
        self.storageDirectory = storageDirectory ?? (
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser
        )
        .appendingPathComponent("MLXtra", isDirectory: true)
    }

    deinit {
        pendingSaveWorkItem?.cancel()
        if let snapshot = pendingSaveSnapshot {
            Self.writeSnapshot(
                snapshot,
                storageDirectory: storageDirectory,
                conversationsURL: storageDirectory.appendingPathComponent("conversations.json"),
                userDefaultsWriter: userDefaultsWriter,
                selectedChatKey: selectedChatKey
            )
        }
        // Use async to avoid deadlock if deinit is called from within the write queue
        writeQueue.async {}
    }

    private var conversationsURL: URL {
        storageDirectory.appendingPathComponent("conversations.json")
    }

    private var attachmentsDirectory: URL {
        storageDirectory.appendingPathComponent("Attachments", isDirectory: true)
    }

    var loadsConversationHistoryAsynchronously: Bool { true }

    func loadChats() -> [Chat] {
        flushPendingWrites()

        return Self.readChats(conversationsURL: conversationsURL)
    }

    func loadConversationSnapshot() async -> ChatPersistenceSnapshot {
        let snapshot = pendingSaveSnapshot
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        pendingSaveSnapshot = nil

        let storageDirectory = storageDirectory
        let conversationsURL = conversationsURL
        let userDefaultsWriter = userDefaultsWriter
        let selectedChatKey = selectedChatKey
        let writeQueue = writeQueue

        return await Task.detached(priority: .utility) {
            if let snapshot {
                Self.writeSnapshot(
                    snapshot,
                    storageDirectory: storageDirectory,
                    conversationsURL: conversationsURL,
                    userDefaultsWriter: userDefaultsWriter,
                    selectedChatKey: selectedChatKey
                )
            }

            writeQueue.sync {}
            return ChatPersistenceSnapshot(
                chats: Self.readChats(conversationsURL: conversationsURL),
                selectedChatId: Self.readSelectedChatId(
                    userDefaultsWriter: userDefaultsWriter,
                    selectedChatKey: selectedChatKey
                )
            )
        }.value
    }

    private nonisolated static func readChats(conversationsURL: URL) -> [Chat] {
        guard FileManager.default.fileExists(atPath: conversationsURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: conversationsURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Chat].self, from: data)
        } catch {
            print("Failed to load conversation history: \(error)")
            return []
        }
    }

    func saveChats(_ chats: [Chat]) {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        pendingSaveSnapshot = nil

        let storageDirectory = storageDirectory
        let conversationsURL = conversationsURL

        writeQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: storageDirectory,
                    withIntermediateDirectories: true
                )

                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601

                let data = try encoder.encode(chats)
                try data.write(to: conversationsURL, options: [.atomic])
            } catch {
                print("Failed to save conversation history: \(error)")
            }
        }
    }

    func scheduleSave(_ chats: [Chat], selectedChatId: UUID?) {
        schedulePendingSave(PendingChatSaveSnapshot(chats: chats, selectedChatId: selectedChatId))
    }

    private func schedulePendingSave(_ snapshot: PendingChatSaveSnapshot) {
        pendingSaveWorkItem?.cancel()
        let storageDirectory = storageDirectory
        let conversationsURL = conversationsURL
        let userDefaultsWriter = userDefaultsWriter
        let selectedChatKey = selectedChatKey
        pendingSaveSnapshot = snapshot
        let workItem = DispatchWorkItem {
            Self.writeSnapshot(
                snapshot,
                storageDirectory: storageDirectory,
                conversationsURL: conversationsURL,
                userDefaultsWriter: userDefaultsWriter,
                selectedChatKey: selectedChatKey
            )
        }
        pendingSaveWorkItem = workItem
        writeQueue.asyncAfter(deadline: .now() + saveDebounceInterval, execute: workItem)
    }

    func flushPendingSave() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        writePendingSaveSnapshot()
    }

    private func writePendingSaveSnapshot() {
        guard let snapshot = pendingSaveSnapshot else { return }
        pendingSaveSnapshot = nil
        writeSnapshot(snapshot)
    }

    private func writeSnapshot(_ snapshot: PendingChatSaveSnapshot) {
        Self.writeSnapshot(
            snapshot,
            storageDirectory: storageDirectory,
            conversationsURL: conversationsURL,
            userDefaultsWriter: userDefaultsWriter,
            selectedChatKey: selectedChatKey
        )
    }

    private nonisolated static func writeSnapshot(
        _ snapshot: PendingChatSaveSnapshot,
        storageDirectory: URL,
        conversationsURL: URL,
        userDefaultsWriter: UserDefaultsWriter,
        selectedChatKey: String
    ) {
        do {
            try FileManager.default.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(snapshot.chats)
            try data.write(to: conversationsURL, options: [.atomic])

            let userDefaults = userDefaultsWriter.userDefaults
            if let selectedChatId = snapshot.selectedChatId {
                userDefaults.set(selectedChatId.uuidString, forKey: selectedChatKey)
            } else {
                userDefaults.removeObject(forKey: selectedChatKey)
            }
        } catch {
            print("Failed to save conversation history: \(error)")
        }
    }

    private func flushPendingWrites() {
        // Also flush any pending debounced save before sync-waiting.
        flushPendingSave()
        writeQueue.sync {}
    }

    func loadSelectedChatId() -> UUID? {
        Self.readSelectedChatId(userDefaultsWriter: userDefaultsWriter, selectedChatKey: selectedChatKey)
    }

    private nonisolated static func readSelectedChatId(
        userDefaultsWriter: UserDefaultsWriter,
        selectedChatKey: String
    ) -> UUID? {
        let userDefaults = userDefaultsWriter.userDefaults
        guard let storedValue = userDefaults.string(forKey: selectedChatKey) else {
            return nil
        }

        return UUID(uuidString: storedValue)
    }

    func saveSelectedChatId(_ selectedChatId: UUID?) {
        if let snapshot = pendingSaveSnapshot {
            schedulePendingSave(PendingChatSaveSnapshot(chats: snapshot.chats, selectedChatId: selectedChatId))
        }

        if let selectedChatId {
            userDefaults.set(selectedChatId.uuidString, forKey: selectedChatKey)
        } else {
            userDefaults.removeObject(forKey: selectedChatKey)
        }
    }

    func persistAttachments(_ urls: [URL], chatId: UUID, messageId: UUID) async -> [URL] {
        guard !urls.isEmpty else { return [] }

        let messageAttachmentsDirectory = attachmentsDirectory
            .appendingPathComponent(chatId.uuidString, isDirectory: true)
            .appendingPathComponent(messageId.uuidString, isDirectory: true)

        return await Task.detached(priority: .utility) {
            Self.copyAttachments(urls, to: messageAttachmentsDirectory)
        }.value
    }

    private nonisolated static func copyAttachments(_ urls: [URL], to messageAttachmentsDirectory: URL) -> [URL] {
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(
                at: messageAttachmentsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            print("Failed to create attachment directory: \(error)")
            return urls
        }

        return urls.enumerated().map { index, sourceURL in
            let destinationURL = messageAttachmentsDirectory
                .appendingPathComponent("\(index)-\(sourceURL.lastPathComponent)")

            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }

                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                return destinationURL
            } catch {
                print("Failed to copy attachment \(sourceURL.path): \(error)")
                return sourceURL
            }
        }
    }

    func deleteAttachments(for chatId: UUID) {
        let chatAttachmentsDirectory = attachmentsDirectory
            .appendingPathComponent(chatId.uuidString, isDirectory: true)

        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: chatAttachmentsDirectory.path) else { return }

            do {
                try fileManager.removeItem(at: chatAttachmentsDirectory)
            } catch {
                print("Failed to delete attachments for chat \(chatId): \(error)")
            }
        }
    }
}
