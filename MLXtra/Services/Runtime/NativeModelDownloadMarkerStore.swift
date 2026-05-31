import Foundation

struct NativeModelDownloadMarkerStore {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func markSnapshotInProgress(at destinationRoot: URL) throws {
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try clearCompletionManifest(at: destinationRoot)
        let markerURL = destinationRoot.appendingPathComponent(NativeSnapshotCompletionManifest.inProgressFilename)
        try Data("in-progress".utf8).write(to: markerURL, options: [.atomic])
    }

    func clearSnapshotInProgress(at destinationRoot: URL) throws {
        let markerURL = destinationRoot.appendingPathComponent(NativeSnapshotCompletionManifest.inProgressFilename)
        if fileManager.fileExists(atPath: markerURL.path) {
            try fileManager.removeItem(at: markerURL)
        }
    }

    func clearCompletionManifest(at destinationRoot: URL) throws {
        let manifestURL = destinationRoot.appendingPathComponent(NativeSnapshotCompletionManifest.filename)
        if fileManager.fileExists(atPath: manifestURL.path) {
            try fileManager.removeItem(at: manifestURL)
        }
    }

    func writeCompletionManifest(
        _ manifest: HuggingFaceManifest,
        destinationRoot: URL
    ) throws {
        let manifestURL = destinationRoot.appendingPathComponent(NativeSnapshotCompletionManifest.filename)
        let data = try JSONEncoder().encode(NativeSnapshotCompletionManifest(manifest: manifest))
        try data.write(to: manifestURL, options: [.atomic])
    }

    func writeRevisionRef(
        revision: String,
        resolvedRevision: String,
        modelCacheRoot: URL
    ) throws {
        let refsRoot = modelCacheRoot.appendingPathComponent("refs")
        let refURL = refsRoot.appendingPathComponent(revision)
        try fileManager.createDirectory(at: refURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(resolvedRevision.utf8).write(to: refURL, options: [.atomic])
    }

    func markAceStepContractInProgress(plan: AceStepDownloadPlan) throws {
        try fileManager.createDirectory(at: plan.checkpointsRoot, withIntermediateDirectories: true)
        let completionURL = plan.checkpointsRoot.appendingPathComponent(AceStepContractCompletionManifest.filename)
        if fileManager.fileExists(atPath: completionURL.path) {
            try fileManager.removeItem(at: completionURL)
        }
        let markerURL = plan.checkpointsRoot.appendingPathComponent(AceStepContractCompletionManifest.inProgressFilename)
        try Data("in-progress".utf8).write(to: markerURL, options: [.atomic])
    }

    func clearAceStepContractInProgress(plan: AceStepDownloadPlan) throws {
        let markerURL = plan.checkpointsRoot.appendingPathComponent(AceStepContractCompletionManifest.inProgressFilename)
        if fileManager.fileExists(atPath: markerURL.path) {
            try fileManager.removeItem(at: markerURL)
        }
    }

    func writeAceStepContractCompletionManifest(plan: AceStepDownloadPlan) throws {
        let manifestURL = plan.checkpointsRoot.appendingPathComponent(AceStepContractCompletionManifest.filename)
        let data = try JSONEncoder().encode(AceStepContractCompletionManifest(plan: plan))
        try data.write(to: manifestURL, options: [.atomic])
    }

    func markAceStepContractComplete(plan: AceStepDownloadPlan) throws {
        try clearSnapshotInProgress(at: plan.checkpointsRoot)
        try clearCompletionManifest(at: plan.checkpointsRoot)
        try clearAceStepContractInProgress(plan: plan)
        try writeAceStepContractCompletionManifest(plan: plan)
    }
}
