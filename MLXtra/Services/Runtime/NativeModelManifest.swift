import Foundation

struct HuggingFaceManifestFile: Equatable {
    let path: String
    let size: Int64?
    let sha256: String?
}

struct HuggingFaceManifest: Equatable {
    let repoID: String
    let revision: String
    let resolvedRevision: String
    let files: [HuggingFaceManifestFile]

    static func parse(data: Data, repoID: String, revision: String) throws -> HuggingFaceManifest {
        let response = try JSONDecoder().decode(HuggingFaceModelAPIResponse.self, from: data)
        let files = response.siblings
            .compactMap { sibling -> HuggingFaceManifestFile? in
                guard let path = sibling.downloadPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !path.isEmpty,
                      !path.hasSuffix("/") else {
                    return nil
                }
                return HuggingFaceManifestFile(
                    path: path,
                    size: sibling.lfs?.size ?? sibling.size,
                    sha256: sibling.lfs?.sha256
                )
            }
            .sorted { $0.path < $1.path }

        guard !files.isEmpty else {
            throw NativeModelDownloadError.emptyManifest(repoID)
        }

        return HuggingFaceManifest(
            repoID: repoID,
            revision: revision,
            resolvedRevision: response.sha ?? revision,
            files: files
        )
    }

    func selectingComponents(_ components: [String]) throws -> HuggingFaceManifest {
        let normalizedComponents = components
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }
        let selectedFiles = files.filter { file in
            normalizedComponents.contains { component in
                file.path == component || file.path.hasPrefix(component + "/")
            }
        }

        guard !selectedFiles.isEmpty else {
            throw NativeModelDownloadError.emptyManifest(repoID)
        }

        return HuggingFaceManifest(
            repoID: repoID,
            revision: revision,
            resolvedRevision: resolvedRevision,
            files: selectedFiles
        )
    }
}

struct NativeSnapshotCompletionManifest: Codable, Equatable {
    struct FileEntry: Codable, Equatable {
        let path: String
        let size: Int64?
        let sha256: String?
    }

    static let filename = ".mlxtra_snapshot_complete.json"
    static let inProgressFilename = ".mlxtra_snapshot_in_progress"
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let repoID: String
    let revision: String
    let resolvedRevision: String
    let files: [FileEntry]

    init(manifest: HuggingFaceManifest) {
        self.schemaVersion = Self.currentSchemaVersion
        self.repoID = manifest.repoID
        self.revision = manifest.revision
        self.resolvedRevision = manifest.resolvedRevision
        self.files = manifest.files.map {
            FileEntry(path: $0.path, size: $0.size, sha256: $0.sha256)
        }
    }

    var manifestFiles: [HuggingFaceManifestFile] {
        files.map { HuggingFaceManifestFile(path: $0.path, size: $0.size, sha256: $0.sha256) }
    }
}

struct AceStepContractCompletionManifest: Codable, Equatable {
    static let filename = ".mlxtra_acestep_contract_complete.json"
    static let inProgressFilename = ".mlxtra_acestep_contract_in_progress"
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let repoID: String
    let revision: String
    let requiredComponents: [String]

    init(plan: AceStepDownloadPlan) {
        self.schemaVersion = Self.currentSchemaVersion
        self.repoID = plan.repoID
        self.revision = plan.revision
        self.requiredComponents = plan.requiredComponents
    }
}

struct AceStepDownloadPlan: Equatable {
    let repoID: String
    let revision: String
    let requiredComponents: [String]
    let checkpointsRoot: URL

    init(
        repoID: String,
        revision: String = "main",
        requiredComponents: [String],
        checkpointsRoot: URL
    ) {
        self.repoID = repoID
        self.revision = revision
        self.requiredComponents = requiredComponents
        self.checkpointsRoot = checkpointsRoot
    }

    func componentURL(component: String) -> URL {
        checkpointsRoot.appendingPathComponent(component)
    }
}

struct ComponentBundleDownloadPlan: Equatable {
    let repoID: String
    let revision: String
    let components: [String]
    let destinationRoot: URL

    init(
        repoID: String,
        revision: String = "main",
        components: [String],
        destinationRoot: URL
    ) {
        self.repoID = repoID
        self.revision = revision
        self.components = components
        self.destinationRoot = destinationRoot
    }
}

private struct HuggingFaceModelAPIResponse: Decodable {
    let sha: String?
    let siblings: [Sibling]

    struct Sibling: Decodable {
        let rfilename: String?
        let pathField: String?
        let size: Int64?
        let lfs: LFS?

        var downloadPath: String? { rfilename ?? pathField }

        private enum CodingKeys: String, CodingKey {
            case rfilename
            case path
            case size
            case lfs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rfilename = try container.decodeIfPresent(String.self, forKey: .rfilename)
            pathField = try container.decodeIfPresent(String.self, forKey: .path)
            size = try container.decodeFlexibleInt64IfPresent(forKey: .size)
            lfs = try container.decodeIfPresent(LFS.self, forKey: .lfs)
        }
    }

    struct LFS: Decodable {
        let size: Int64?
        let sha256: String?

        private enum CodingKeys: String, CodingKey {
            case size
            case sha256
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            size = try container.decodeFlexibleInt64IfPresent(forKey: .size)
            sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleInt64IfPresent(forKey key: Key) throws -> Int64? {
        if let value = try decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try decodeIfPresent(Int.self, forKey: key) {
            return Int64(value)
        }
        if let value = try decodeIfPresent(Double.self, forKey: key) {
            return Int64(value)
        }
        if let value = try decodeIfPresent(String.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }
}
