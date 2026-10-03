import Foundation
import GRDB

nonisolated struct BenchReference: Equatable, Identifiable, Sendable {
    let item: LibraryItem
    let owner: LibraryItemOwner
    let asset: FileAsset?
    var id: UUID { item.id }

    var label: String { "\(owner.scope) · \(item.kind.rawValue) · \(item.title)" }
}

nonisolated struct BenchSnapshot: Sendable {
    var jobs: [JobRecord] = []
    var watches: [WatchRecord] = []
    var calibers: [CaliberRecord] = []
    var items: [LibraryItem] = []
    var assets: [FileAsset] = []

    static func fetch(_ db: Database) throws -> Self {
        try Self(
            jobs: JobQueries.fetchAll(db), watches: WatchQueries.fetchAll(db),
            calibers: CaliberQueries.fetchAll(db), items: LibraryItemQueries.fetchAll(db),
            assets: FileAsset.fetchAll(db))
    }

    func references(for jobID: UUID?) -> [BenchReference] {
        guard let job = jobs.first(where: { $0.id == jobID }),
            let watch = watches.first(where: { $0.id == job.watchID })
        else { return [] }
        var owners: [LibraryItemOwner] = [.job(job.id), .watch(watch.id)]
        if let caliberID = watch.caliberID, calibers.contains(where: { $0.id == caliberID }) {
            owners.append(.caliber(caliberID))
        }
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        return items.compactMap { item in
            guard let owner = owners.first(where: item.belongs) else { return nil }
            if item.kind == .link {
                guard ReferenceDraft.parsedURL(item.sourceURL) != nil else { return nil }
                return BenchReference(item: item, owner: owner, asset: nil)
            }
            guard let assetID = item.fileAssetID, let asset = assetsByID[assetID] else {
                return nil
            }
            if item.kind == .document {
                guard asset.detectedType == .pdf else { return nil }
            } else {
                guard asset.detectedType != .pdf else { return nil }
            }
            return BenchReference(item: item, owner: owner, asset: asset)
        }
    }
}

nonisolated struct BenchReferenceService: Sendable {
    let coordinator: LibraryCoordinator

    func validate(_ reference: BenchReference) async throws {
        if let asset = reference.asset {
            _ = try await coordinator.originalURL(for: asset.id)
        }
    }
}
