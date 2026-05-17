import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AppUpdateController {
#if canImport(Sparkle)
    private let updaterController: SPUStandardUpdaterController?
#endif

    init(startingUpdater: Bool = true) {
#if canImport(Sparkle)
        guard Self.isConfiguredForUpdates else {
            updaterController = nil
            return
        }

#if DEBUG
        if ProcessInfo.processInfo.environment["MLXTRA_UI_TEST_MODE"] == "1" {
            updaterController = nil
            return
        }
#endif

        updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
#endif
    }

    var canCheckForUpdates: Bool {
#if canImport(Sparkle)
        updaterController != nil
#else
        false
#endif
    }

    func checkForUpdates() {
#if canImport(Sparkle)
        updaterController?.checkForUpdates(nil)
#endif
    }

    private static var isConfiguredForUpdates: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return isUsableUpdateConfiguration(
            feedURL: info["SUFeedURL"] as? String,
            publicKey: info["SUPublicEDKey"] as? String
        )
    }

    static func isUsableUpdateConfiguration(feedURL: String?, publicKey: String?) -> Bool {
        guard isConcreteValue(feedURL),
              let url = URL(string: feedURL ?? ""),
              url.scheme == "https" else {
            return false
        }

        return isConcreteValue(publicKey)
    }

    private static func isConcreteValue(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("$(")
    }
}
