import XCTest
@testable import MLXHub

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

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXHubTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeUserDefaults() throws -> (UserDefaults, String) {
        let suiteName = "MLXHubTests.\(UUID().uuidString)"
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
