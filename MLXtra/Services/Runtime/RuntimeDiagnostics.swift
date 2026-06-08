import Combine
import Foundation

enum DiagnosticsLogLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case debug
    case info
    case warning
    case error

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }

    var severity: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    var isAlwaysCaptured: Bool {
        severity >= DiagnosticsLogLevel.warning.severity
    }
}

enum DiagnosticsLogCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case app = "App"
    case bridge = "Bridge"
    case download = "Download"
    case generation = "Generation"
    case runtime = "Runtime"
    case updates = "Updates"

    var id: String { rawValue }
}

struct DiagnosticsLogEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: DiagnosticsLogLevel
    let category: DiagnosticsLogCategory
    let message: String
    let details: String?
}

private actor DiagnosticsLogFileWriter {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func append(_ entry: DiagnosticsLogEntry) {
        do {
            try ensureFileExists()
            let line = Self.line(for: entry)
            guard let data = line.data(using: .utf8) else { return }

            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            print("[Diagnostics] Failed to append diagnostics log: \(error.localizedDescription)")
        }
    }

    func read() -> String {
        do {
            try ensureFileExists()
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            return "Unable to read diagnostics log: \(error.localizedDescription)"
        }
    }

    func clear() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: fileURL, options: .atomic)
        } catch {
            print("[Diagnostics] Failed to clear diagnostics log: \(error.localizedDescription)")
        }
    }

    func ensureFile() {
        do {
            try ensureFileExists()
        } catch {
            print("[Diagnostics] Failed to prepare diagnostics log: \(error.localizedDescription)")
        }
    }

    private func ensureFileExists() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    private static func line(for entry: DiagnosticsLogEntry) -> String {
        let timestamp = ISO8601DateFormatter().string(from: entry.timestamp)
        var line = "\(timestamp) [\(entry.level.displayName.uppercased())] [\(entry.category.rawValue)] \(entry.message)"

        if let details = entry.details?.trimmingCharacters(in: .whitespacesAndNewlines),
           !details.isEmpty {
            let indentedDetails = details
                .components(separatedBy: .newlines)
                .map { "    \($0)" }
                .joined(separator: "\n")
            line += "\n\(indentedDetails)"
        }

        return line + "\n"
    }
}

@MainActor
final class DiagnosticsLogStore: ObservableObject {
    nonisolated static let isEnabledKey = "MLXtra.diagnostics.enabled"
    nonisolated static let verboseBridgeLoggingEnabledKey = "MLXtra.diagnostics.verboseBridgeLogging"
    static let shared = DiagnosticsLogStore()

    private nonisolated static let maximumRecentEntries = 1_000

    @Published private(set) var entries: [DiagnosticsLogEntry] = []
    @Published var isEnabled: Bool {
        didSet {
            userDefaults.set(isEnabled, forKey: Self.isEnabledKey)
            if isEnabled, oldValue != isEnabled {
                record("Diagnostic logging enabled", category: .app, level: .info)
            }
        }
    }
    @Published var verboseBridgeLoggingEnabled: Bool {
        didSet {
            userDefaults.set(verboseBridgeLoggingEnabled, forKey: Self.verboseBridgeLoggingEnabledKey)
            userDefaults.set(verboseBridgeLoggingEnabled, forKey: "MLXtra.bridgeDebug")
            if verboseBridgeLoggingEnabled, oldValue != verboseBridgeLoggingEnabled {
                record("Verbose bridge logging enabled", category: .bridge, level: .info)
            }
        }
    }

    let logFileURL: URL

    private let userDefaults: UserDefaults
    private let fileWriter: DiagnosticsLogFileWriter

    init(
        userDefaults: UserDefaults = .standard,
        logDirectoryURL: URL = DiagnosticsLogStore.defaultLogDirectoryURL()
    ) {
        self.userDefaults = userDefaults
        self.isEnabled = userDefaults.bool(forKey: Self.isEnabledKey)
        self.verboseBridgeLoggingEnabled = userDefaults.bool(forKey: Self.verboseBridgeLoggingEnabledKey)
            || userDefaults.bool(forKey: "MLXtra.bridgeDebug")
        self.logFileURL = logDirectoryURL.appendingPathComponent("diagnostics.log")
        self.fileWriter = DiagnosticsLogFileWriter(fileURL: self.logFileURL)
    }

    nonisolated static var isDiagnosticsEnabled: Bool {
        UserDefaults.standard.bool(forKey: isEnabledKey)
    }

    nonisolated static var isVerboseBridgeLoggingEnabled: Bool {
        UserDefaults.standard.bool(forKey: verboseBridgeLoggingEnabledKey)
            || UserDefaults.standard.bool(forKey: "MLXtra.bridgeDebug")
    }

    nonisolated static func shouldCapture(level: DiagnosticsLogLevel) -> Bool {
        level.isAlwaysCaptured || isDiagnosticsEnabled || isVerboseBridgeLoggingEnabled
    }

    nonisolated static func log(
        _ message: String,
        category: DiagnosticsLogCategory = .app,
        level: DiagnosticsLogLevel = .info,
        details: String? = nil
    ) {
        guard shouldCapture(level: level) else { return }
        Task { @MainActor in
            shared.record(message, category: category, level: level, details: details)
        }
    }

    nonisolated static func capture(
        _ message: String,
        category: DiagnosticsLogCategory = .app,
        level: DiagnosticsLogLevel = .info,
        details: String? = nil
    ) {
        Task { @MainActor in
            shared.record(message, category: category, level: level, details: details, force: true)
        }
    }

    func record(
        _ message: String,
        category: DiagnosticsLogCategory = .app,
        level: DiagnosticsLogLevel = .info,
        details: String? = nil,
        timestamp: Date = Date(),
        force: Bool = false
    ) {
        guard force || level.isAlwaysCaptured || isEnabled || verboseBridgeLoggingEnabled else { return }

        let entry = DiagnosticsLogEntry(
            id: UUID(),
            timestamp: timestamp,
            level: level,
            category: category,
            message: message,
            details: details
        )

        entries.append(entry)
        if entries.count > Self.maximumRecentEntries {
            entries.removeFirst(entries.count - Self.maximumRecentEntries)
        }

        Task {
            await fileWriter.append(entry)
        }
    }

    func exportText() async -> String {
        await fileWriter.read()
    }

    func prepareLogFile() async {
        await fileWriter.ensureFile()
    }

    func clear() {
        entries.removeAll()
        Task {
            await fileWriter.clear()
        }
    }

    private static func defaultLogDirectoryURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        return applicationSupportDirectory
            .appendingPathComponent("MLXtra", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }
}

enum RuntimeDiagnostics {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MLXTRA_RUNTIME_DEBUG"] == "1"
            || UserDefaults.standard.bool(forKey: "MLXtra.runtimeDebug")
            || DiagnosticsLogStore.isDiagnosticsEnabled
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        print(text)
        DiagnosticsLogStore.log(text, category: .runtime, level: .debug)
    }
}
