import XCTest
@testable import MLXtra

@MainActor
final class DiagnosticsLogStoreTests: XCTestCase {
    func testRecordStoresRecentEntriesAndWritesFileWhenEnabled() async throws {
        let store = makeStore(isEnabled: true)

        store.record(
            "Image generation progress 60%",
            category: .generation,
            level: .info,
            details: "Phase: denoising"
        )
        try await waitForLogWrite()

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.category, .generation)

        let text = await store.exportText()
        XCTAssertTrue(text.contains("Image generation progress 60%"))
        XCTAssertTrue(text.contains("Phase: denoising"))
    }

    func testInfoIsIgnoredWhenDiagnosticsDisabledButWarningIsCaptured() async throws {
        let store = makeStore(isEnabled: false)

        store.record("Normal status", category: .generation, level: .info)
        store.record("Retrying local engine", category: .generation, level: .warning)
        try await waitForLogWrite()

        XCTAssertEqual(store.entries.map(\.message), ["Retrying local engine"])

        let text = await store.exportText()
        XCTAssertFalse(text.contains("Normal status"))
        XCTAssertTrue(text.contains("Retrying local engine"))
    }

    func testVerboseBridgeLoggingCapturesDebugWhenDiagnosticsDisabled() async throws {
        let store = makeStore(isEnabled: false, verboseBridgeLoggingEnabled: true)

        store.record("Python stderr line", category: .bridge, level: .debug)
        try await waitForLogWrite()

        XCTAssertEqual(store.entries.map(\.message), ["Python stderr line"])

        let text = await store.exportText()
        XCTAssertTrue(text.contains("Python stderr line"))
    }

    func testClearRemovesRecentEntriesAndPersistentLog() async throws {
        let store = makeStore(isEnabled: true)

        store.record("A captured event", category: .app, level: .info)
        try await waitForLogWrite()
        store.clear()
        try await waitForLogWrite()

        XCTAssertTrue(store.entries.isEmpty)
        let text = await store.exportText()
        XCTAssertEqual(text, "")
    }

    private func makeStore(
        isEnabled: Bool,
        verboseBridgeLoggingEnabled: Bool = false
    ) -> DiagnosticsLogStore {
        let suiteName = "MLXtraTests.Diagnostics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(isEnabled, forKey: DiagnosticsLogStore.isEnabledKey)
        defaults.set(verboseBridgeLoggingEnabled, forKey: DiagnosticsLogStore.verboseBridgeLoggingEnabledKey)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXtraDiagnosticsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        return DiagnosticsLogStore(userDefaults: defaults, logDirectoryURL: directory)
    }

    private func waitForLogWrite() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}
