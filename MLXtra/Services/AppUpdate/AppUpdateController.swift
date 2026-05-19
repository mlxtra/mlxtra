import Combine
import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AppUpdateController: NSObject, ObservableObject {
    enum Status: Equatable {
        case unavailable
        case idle
        case checking
        case upToDate
        case updateAvailable(String)
        case failed(String)
    }

    @Published private(set) var status: Status

#if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
#endif

    init(startingUpdater: Bool = true) {
#if canImport(Sparkle)
        guard Self.isConfiguredForUpdates else {
            updaterController = nil
            status = .unavailable
            super.init()
            return
        }

#if DEBUG
        if ProcessInfo.processInfo.environment["MLXTRA_UI_TEST_MODE"] == "1" {
            updaterController = nil
            status = .unavailable
            super.init()
            return
        }
#endif

        status = .idle
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
#else
        status = .unavailable
        super.init()
#endif
    }

    var canCheckForUpdates: Bool {
#if canImport(Sparkle)
        updaterController?.updater.canCheckForUpdates == true
#else
        false
#endif
    }

    func checkForUpdates() {
#if canImport(Sparkle)
        guard canCheckForUpdates else { return }
        status = .checking
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

#if canImport(Sparkle)
extension AppUpdateController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString.isEmpty ? item.versionString : item.displayVersionString
        status = .updateAvailable(version)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        status = .upToDate
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        status = .upToDate
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard status != .upToDate else { return }
        status = .failed(error.localizedDescription)
    }
}
#endif
