import XCTest
@testable import MLXtra

@MainActor
final class ChatPersistenceServiceTests: XCTestCase {
    func testSaveAndLoadChatsRoundTrip() throws {
        let storageDirectory = try makeTemporaryDirectory()
        let (defaults, suiteName) = try makeUserDefaults()
        defer { cleanup(defaults: defaults, suiteName: suiteName, directory: storageDirectory) }

        let service = LocalChatPersistenceService(
            userDefaults: defaults,
            storageDirectory: storageDirectory
        )
        let chat = Chat(
            title: "Saved chat",
            messages: [
                Message(
                    content: "Hello",
                    isUser: true,
                    timestamp: Date(timeIntervalSince1970: 1_234)
                )
            ],
            timestamp: Date(timeIntervalSince1970: 5_678),
            icon: "message"
        )

        service.saveChats([chat])

        let loadedChats = service.loadChats()
        XCTAssertEqual(loadedChats, [chat])
    }

    func testFlushPendingSavePersistsDebouncedSnapshotImmediately() throws {
        let storageDirectory = try makeTemporaryDirectory()
        let (defaults, suiteName) = try makeUserDefaults()
        defer { cleanup(defaults: defaults, suiteName: suiteName, directory: storageDirectory) }

        let service = LocalChatPersistenceService(
            userDefaults: defaults,
            storageDirectory: storageDirectory
        )
        let chat = Chat(
            title: "Pending chat",
            messages: [
                Message(
                    content: "Saved before debounce fires",
                    isUser: false,
                    timestamp: Date(timeIntervalSince1970: 1_234)
                )
            ],
            timestamp: Date(timeIntervalSince1970: 5_678),
            icon: "message"
        )

        service.scheduleSave([chat], selectedChatId: chat.id)
        service.flushPendingSave()

        XCTAssertEqual(service.loadChats(), [chat])
        XCTAssertEqual(service.loadSelectedChatId(), chat.id)
    }

    func testDeinitPersistsDebouncedSnapshot() throws {
        let storageDirectory = try makeTemporaryDirectory()
        let (defaults, suiteName) = try makeUserDefaults()
        defer { cleanup(defaults: defaults, suiteName: suiteName, directory: storageDirectory) }

        let chat = Chat(
            title: "Closing chat",
            messages: [
                Message(
                    content: "Saved during teardown",
                    isUser: false,
                    timestamp: Date(timeIntervalSince1970: 2_468)
                )
            ],
            timestamp: Date(timeIntervalSince1970: 1_357),
            icon: "message"
        )

        var service: LocalChatPersistenceService? = LocalChatPersistenceService(
            userDefaults: defaults,
            storageDirectory: storageDirectory
        )
        service?.scheduleSave([chat], selectedChatId: chat.id)
        service = nil

        let reloadedService = LocalChatPersistenceService(
            userDefaults: defaults,
            storageDirectory: storageDirectory
        )
        XCTAssertEqual(reloadedService.loadChats(), [chat])
        XCTAssertEqual(reloadedService.loadSelectedChatId(), chat.id)
    }

    func testSelectedChatIdRoundTrip() throws {
        let storageDirectory = try makeTemporaryDirectory()
        let (defaults, suiteName) = try makeUserDefaults()
        defer { cleanup(defaults: defaults, suiteName: suiteName, directory: storageDirectory) }

        let service = LocalChatPersistenceService(
            userDefaults: defaults,
            storageDirectory: storageDirectory
        )
        let chatId = UUID()

        service.saveSelectedChatId(chatId)
        XCTAssertEqual(service.loadSelectedChatId(), chatId)

        service.saveSelectedChatId(nil)
        XCTAssertNil(service.loadSelectedChatId())
    }

    func testPersistAttachmentsCopiesFilesAndDeleteRemovesChatDirectory() throws {
        let storageDirectory = try makeTemporaryDirectory()
        let (defaults, suiteName) = try makeUserDefaults()
        defer { cleanup(defaults: defaults, suiteName: suiteName, directory: storageDirectory) }

        let service = LocalChatPersistenceService(
            userDefaults: defaults,
            storageDirectory: storageDirectory
        )
        let sourceFile = storageDirectory.appendingPathComponent("source.txt")
        try Data("attachment".utf8).write(to: sourceFile)

        let chatId = UUID()
        let messageId = UUID()
        let persistedURLs = service.persistAttachments([sourceFile], chatId: chatId, messageId: messageId)

        XCTAssertEqual(persistedURLs.count, 1)
        XCTAssertNotEqual(persistedURLs[0], sourceFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedURLs[0].path))
        XCTAssertTrue(persistedURLs[0].path.contains(chatId.uuidString))
        XCTAssertTrue(persistedURLs[0].path.contains(messageId.uuidString))
        XCTAssertEqual(try String(contentsOf: persistedURLs[0]), "attachment")

        service.deleteAttachments(for: chatId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistedURLs[0].deletingLastPathComponent().path))
    }

    func testGeneratedMediaURLsRoundTripEvenWhenFilesAreMissing() throws {
        let storageDirectory = try makeTemporaryDirectory()
        let (defaults, suiteName) = try makeUserDefaults()
        defer { cleanup(defaults: defaults, suiteName: suiteName, directory: storageDirectory) }

        let service = LocalChatPersistenceService(
            userDefaults: defaults,
            storageDirectory: storageDirectory
        )
        let imageURL = storageDirectory.appendingPathComponent("missing-image.png")
        let audioURL = storageDirectory.appendingPathComponent("missing-audio.wav")
        let chat = Chat(
            title: "Generated media",
            messages: [
                Message(
                    content: "Generated output",
                    isUser: false,
                    timestamp: Date(timeIntervalSince1970: 1_234),
                    imageURLs: [imageURL],
                    audioURLs: [audioURL]
                )
            ],
            timestamp: Date(timeIntervalSince1970: 5_678),
            icon: "message"
        )

        service.saveChats([chat])

        let loadedChats = service.loadChats()
        XCTAssertEqual(loadedChats.first?.messages.first?.imageURLs, [imageURL])
        XCTAssertEqual(loadedChats.first?.messages.first?.audioURLs, [audioURL])
    }

    func testCorruptedConversationHistoryLoadsAsEmpty() throws {
        let storageDirectory = try makeTemporaryDirectory()
        let (defaults, suiteName) = try makeUserDefaults()
        defer { cleanup(defaults: defaults, suiteName: suiteName, directory: storageDirectory) }

        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try Data("{ invalid json".utf8)
            .write(to: storageDirectory.appendingPathComponent("conversations.json"))

        let service = LocalChatPersistenceService(
            userDefaults: defaults,
            storageDirectory: storageDirectory
        )

        XCTAssertEqual(service.loadChats(), [])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXtraTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeUserDefaults() throws -> (UserDefaults, String) {
        let suiteName = "MLXtraTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("Failed to create isolated UserDefaults suite")
        }
        return (defaults, suiteName)
    }

    private func cleanup(defaults: UserDefaults, suiteName: String, directory: URL) {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
