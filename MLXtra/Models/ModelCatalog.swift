import Combine
import Foundation

struct ReleaseChannelManifest: Codable, Equatable {
    let schemaVersion: Int
    let channel: String
    let catalog: CatalogReleaseAsset
    let runtimes: [RuntimeReleaseAsset]

    static let defaultChannelURL = URL(string: "https://github.com/mlxtra/mlxtra/releases/latest/download/stable-channel.json")!
}

struct CatalogReleaseAsset: Codable, Equatable {
    let version: String
    let url: URL
    let sha256: String
    let sizeBytes: Int64?
}

struct RuntimeReleaseAsset: Codable, Equatable, Identifiable {
    let version: String
    let platform: String
    let arch: String
    let url: URL
    let sha256: String
    let sizeBytes: Int64?
    let compatibilityApi: Int

    var id: String { "\(platform)-\(arch)-\(version)" }
}

struct ModelCatalog: Codable, Equatable {
    let schemaVersion: Int
    let catalogVersion: String
    let minAppVersion: String?
    let models: [ModelCapabilityProfile]

    var profiles: [ModelCapabilityProfile] { models }
}

enum ModelCatalogError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case incompatibleAppVersion(String)
    case checksumMismatch
    case emptyCatalog
    case duplicateModelId(String)
    case invalidParameter(String)
    case invalidReleaseURL(URL)
    case badHTTPStatus(Int, URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported model catalog schema \(version)"
        case .incompatibleAppVersion(let version):
            return "Model catalog requires MLXtra \(version) or newer"
        case .checksumMismatch:
            return "Model catalog checksum did not match"
        case .emptyCatalog:
            return "Model catalog does not contain any models"
        case .duplicateModelId(let id):
            return "Model catalog contains duplicate model id \(id)"
        case .invalidParameter(let message):
            return "Model catalog contains an invalid parameter: \(message)"
        case .invalidReleaseURL(let url):
            return "Model catalog release URL must use HTTPS: \(url.absoluteString)"
        case .badHTTPStatus(let status, let url):
            return "Model catalog request failed with HTTP \(status): \(url.absoluteString)"
        }
    }
}

final class ModelCatalogService: ObservableObject, @unchecked Sendable {
    static let shared = ModelCatalogService()

    @Published private(set) var catalog: ModelCatalog
    @Published private(set) var lastRefreshError: String?

    var profiles: [ModelCapabilityProfile] {
        catalogLock.lock()
        defer { catalogLock.unlock() }
        return catalogSnapshot.profiles
    }

    init(
        fileManager: FileManager = .default,
        bundle: Bundle? = nil,
        loadCachedCatalog: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
        loadBundledCatalog: Bool = true
    ) {
        let initialCatalog = Self.loadInitialCatalog(
            fileManager: fileManager,
            bundle: bundle,
            loadCachedCatalog: loadCachedCatalog,
            loadBundledCatalog: loadBundledCatalog
        )
        self.fileManager = fileManager
        self.bundle = bundle
        self.catalog = initialCatalog
        self.catalogSnapshot = initialCatalog
    }

    func profile(legacyModel: AIModel) -> ModelCapabilityProfile? {
        profiles.first { $0.aiModel == legacyModel }
    }

    func profile(modelId: String) -> ModelCapabilityProfile? {
        profiles.first { $0.modelId == modelId }
    }

    @MainActor
    func refreshFromStableChannel(
        channelURL: URL = ReleaseChannelManifest.defaultChannelURL
    ) async {
        do {
            guard channelURL.scheme?.lowercased() == "https" else {
                throw ModelCatalogError.invalidReleaseURL(channelURL)
            }
            let channelData = try await Self.fetchValidatedData(from: channelURL)
            let channel = try JSONDecoder.catalogDecoder.decode(ReleaseChannelManifest.self, from: channelData)
            guard channel.catalog.url.scheme?.lowercased() == "https" else {
                throw ModelCatalogError.invalidReleaseURL(channel.catalog.url)
            }
            let catalogData = try await Self.fetchValidatedData(from: channel.catalog.url)
            let refreshed = try Self.decodeCatalog(
                data: catalogData,
                expectedSHA256: channel.catalog.sha256,
                appVersion: Self.currentAppVersion
            )
            try saveCachedCatalog(catalogData)
            setCatalog(Self.catalogWithRequiredBuiltIns(refreshed))
            lastRefreshError = nil
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    static func decodeCatalog(
        data: Data,
        expectedSHA256: String? = nil,
        appVersion: String? = currentAppVersion
    ) throws -> ModelCatalog {
        if let expectedSHA256, !expectedSHA256.isEmpty {
            guard SHA256Checksum.hexDigest(for: data).caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                throw ModelCatalogError.checksumMismatch
            }
        }

        let catalog = try JSONDecoder.catalogDecoder.decode(ModelCatalog.self, from: data)
        try validate(catalog, appVersion: appVersion)
        return catalog
    }

    private let fileManager: FileManager
    private let bundle: Bundle?
    private let catalogLock = NSLock()
    private var catalogSnapshot: ModelCatalog

    @MainActor
    private func setCatalog(_ newCatalog: ModelCatalog) {
        catalogLock.lock()
        catalogSnapshot = newCatalog
        catalogLock.unlock()
        catalog = newCatalog
    }

    private static func fetchValidatedData(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            return data
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ModelCatalogError.badHTTPStatus(httpResponse.statusCode, url)
        }
        return data
    }

    private static func loadInitialCatalog(
        fileManager: FileManager,
        bundle: Bundle?,
        loadCachedCatalog: Bool,
        loadBundledCatalog: Bool
    ) -> ModelCatalog {
        let cachedCatalog: ModelCatalog? = {
            guard loadCachedCatalog,
                  let data = try? Data(contentsOf: cachedCatalogURL(fileManager: fileManager)) else {
                return nil
            }
            return try? decodeCatalog(data: data)
        }()

        let bundledCatalog: ModelCatalog? = {
            guard loadBundledCatalog,
                  let data = bundledCatalogData(bundle: bundle) else {
                return nil
            }
            return try? decodeCatalog(data: data)
        }()

        if let cachedCatalog, let bundledCatalog {
            let preferred = VersionComparator.compare(
                bundledCatalog.catalogVersion,
                cachedCatalog.catalogVersion
            ) == .orderedDescending ? bundledCatalog : cachedCatalog
            return catalogWithRequiredBuiltIns(preferred)
        }

        if let cachedCatalog {
            return catalogWithRequiredBuiltIns(cachedCatalog)
        }

        if let bundledCatalog {
            return catalogWithRequiredBuiltIns(bundledCatalog)
        }

        return catalogWithRequiredBuiltIns(legacyFallbackCatalog)
    }

    private static func validate(_ catalog: ModelCatalog, appVersion: String?) throws {
        guard catalog.schemaVersion == 1 else {
            throw ModelCatalogError.unsupportedSchema(catalog.schemaVersion)
        }
        guard !catalog.models.isEmpty else {
            throw ModelCatalogError.emptyCatalog
        }
        if let minAppVersion = catalog.minAppVersion,
           let appVersion,
           VersionComparator.compare(appVersion, minAppVersion) == .orderedAscending {
            throw ModelCatalogError.incompatibleAppVersion(minAppVersion)
        }

        var seenIds = Set<String>()
        var seenModelIds = Set<String>()
        for profile in catalog.models {
            guard seenIds.insert(profile.id).inserted else {
                throw ModelCatalogError.duplicateModelId(profile.id)
            }
            guard seenModelIds.insert(profile.modelId).inserted else {
                throw ModelCatalogError.duplicateModelId(profile.modelId)
            }
            try validateParameters(profile.parameters, profileId: profile.id)
        }
    }

    private static func validateParameters(
        _ parameters: [ModelParameterDefinition],
        profileId: String
    ) throws {
        var seenKeys = Set<String>()
        for parameter in parameters {
            let key = parameter.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw ModelCatalogError.invalidParameter("\(profileId) has an empty parameter key")
            }
            guard seenKeys.insert(key).inserted else {
                throw ModelCatalogError.invalidParameter("\(profileId) has duplicate parameter key \(key)")
            }

            if let range = parameter.range, range.lowerBound > range.upperBound {
                throw ModelCatalogError.invalidParameter("\(profileId).\(key) has an invalid range")
            }

            switch parameter.type {
            case .decimal:
                try validateNumericDefault(parameter, key: key, profileId: profileId, integerOnly: false)
            case .integer:
                try validateNumericDefault(parameter, key: key, profileId: profileId, integerOnly: true)
            case .boolean:
                guard parameter.typedValue(from: parameter.defaultValue) != nil else {
                    throw ModelCatalogError.invalidParameter("\(profileId).\(key) has an invalid boolean default")
                }
            case .option:
                guard !parameter.options.isEmpty else {
                    throw ModelCatalogError.invalidParameter("\(profileId).\(key) has no options")
                }
                guard parameter.options.contains(parameter.defaultValue) else {
                    throw ModelCatalogError.invalidParameter("\(profileId).\(key) default is not in options")
                }
            case .text:
                break
            }
        }
    }

    private static func validateNumericDefault(
        _ parameter: ModelParameterDefinition,
        key: String,
        profileId: String,
        integerOnly: Bool
    ) throws {
        guard parameter.step > 0, parameter.step.isFinite else {
            throw ModelCatalogError.invalidParameter("\(profileId).\(key) has a non-positive step")
        }
        guard let value = Double(parameter.defaultValue), value.isFinite else {
            throw ModelCatalogError.invalidParameter("\(profileId).\(key) has an invalid numeric default")
        }
        if integerOnly, value.rounded() != value {
            throw ModelCatalogError.invalidParameter("\(profileId).\(key) has a non-integer default")
        }
        if let range = parameter.range,
           !(range.lowerBound...range.upperBound).contains(value) {
            throw ModelCatalogError.invalidParameter("\(profileId).\(key) default is outside its range")
        }
    }

    private static func bundledCatalogData(bundle explicitBundle: Bundle?) -> Data? {
        let bundles: [Bundle] = {
            if let explicitBundle {
                return [explicitBundle]
            }
#if SWIFT_PACKAGE
            return [Bundle.module, Bundle.main]
#else
            return [Bundle.main]
#endif
        }()

        for bundle in bundles {
            if let url = bundle.url(forResource: "model-catalog", withExtension: "json"),
               let data = try? Data(contentsOf: url) {
                return data
            }
        }
        return nil
    }

    private func saveCachedCatalog(_ data: Data) throws {
        let url = Self.cachedCatalogURL(fileManager: fileManager)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func cachedCatalogURL(fileManager: FileManager) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("MLXtra")
            .appendingPathComponent("Catalog")
            .appendingPathComponent("model-catalog.json")
    }

    private static var currentAppVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private static var legacyFallbackCatalog: ModelCatalog {
        ModelCatalog(
            schemaVersion: 1,
            catalogVersion: "fallback",
            minAppVersion: nil,
            models: LegacyModelCatalog.profiles
        )
    }

    private static func catalogWithRequiredBuiltIns(_ catalog: ModelCatalog) -> ModelCatalog {
        var models = catalog.models
        var existingIds = Set(models.map(\.id))
        var existingModelIds = Set(models.map(\.modelId))

        for profile in LegacyModelCatalog.profiles
            where existingIds.insert(profile.id).inserted
                && existingModelIds.insert(profile.modelId).inserted {
            models.append(profile)
        }

        return ModelCatalog(
            schemaVersion: catalog.schemaVersion,
            catalogVersion: catalog.catalogVersion,
            minAppVersion: catalog.minAppVersion,
            models: models
        )
    }
}

private extension JSONDecoder {
    static var catalogDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }
}
