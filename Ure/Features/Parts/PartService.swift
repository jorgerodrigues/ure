import AppKit
import Foundation
import GRDB

nonisolated enum PartError: LocalizedError, Equatable {
    case missingRecord
    case jobMismatch
    case linkMismatch

    var errorDescription: String? {
        switch self {
        case .missingRecord: "This part is no longer available. Your draft has been kept."
        case .jobMismatch: "This part belongs to another job. Your draft has been kept."
        case .linkMismatch:
            "A link belongs to another part or occurs twice. Your draft has been kept."
        }
    }
}

nonisolated struct PartService: Sendable {
    let coordinator: LibraryCoordinator
    var openBrowser: @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }

    func save(_ draft: PartDraft, for jobID: UUID, editing id: UUID?) async throws
        -> PartRequirement
    {
        try await coordinator.mutate { db, _, dependencies in
            _ = try JobService.requireOpenJob(jobID, in: db)
            var existing: PartRequirement?
            if let id {
                guard let part = try PartQueries.fetch(id, in: db) else {
                    throw PartError.missingRecord
                }
                guard part.record.jobID == jobID else { throw PartError.jobMismatch }
                existing = part
            }
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            let record = try draft.record(
                id: existing?.id ?? dependencies.makeID(), jobID: jobID,
                status: existing?.record.status ?? .needed,
                createdAt: existing?.record.createdAt ?? now, updatedAt: now)
            var seen: Set<UUID> = []
            var links: [PartLink] = []
            for (position, link) in draft.links.enumerated() {
                guard seen.insert(link.id).inserted else { throw PartError.linkMismatch }
                let saved = try PartLink.fetchOne(db, key: link.id.uuidString)
                if let saved, saved.partID != record.id { throw PartError.linkMismatch }
                let url = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
                var candidate = PartLink(
                    id: link.id, partID: record.id, position: position, url: url,
                    title: JobDraft.optional(link.title),
                    supplierName: JobDraft.optional(link.supplierName),
                    supplierStockCode: JobDraft.optional(link.supplierStockCode),
                    price: JobDraft.optional(link.price),
                    currency: JobDraft.optional(link.currency)?.uppercased(),
                    notes: JobDraft.optional(link.notes),
                    isSelected: draft.selectedLinkID == link.id,
                    createdAt: saved?.createdAt ?? now, updatedAt: saved?.updatedAt ?? now)
                if let saved, saved != candidate {
                    candidate.updatedAt = now
                }
                links.append(candidate)
            }
            let result = PartRequirement(record: record, links: links)
            if let existing, PartDraft(part: existing) == PartDraft(part: result) {
                return existing
            }
            if existing != nil { try record.update(db) } else { try record.insert(db) }
            if existing?.selectedLink?.id != draft.selectedLinkID {
                try db.execute(
                    sql: "UPDATE partLink SET isSelected = 0 WHERE partID = ? AND isSelected = 1",
                    arguments: [record.id.uuidString])
            }
            for link in existing?.links ?? [] where !seen.contains(link.id) {
                try link.delete(db)
            }
            for link in links { try link.save(db) }
            return result
        }
    }

    @MainActor
    func open(_ link: PartLink) throws {
        guard let url = ReferenceDraft.parsedURL(link.url) else { throw ReferenceError.invalidURL }
        guard openBrowser(url) else { throw ReferenceError.browserUnavailable }
    }
}
