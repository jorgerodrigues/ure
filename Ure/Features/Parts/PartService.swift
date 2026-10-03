import AppKit
import Foundation
import GRDB

nonisolated enum PartError: LocalizedError, Equatable {
    case missingRecord
    case jobMismatch
    case linkMismatch
    case staleStatus

    var errorDescription: String? {
        switch self {
        case .missingRecord: "This part is no longer available. Your draft has been kept."
        case .jobMismatch: "This part belongs to another job. Your draft has been kept."
        case .linkMismatch:
            "A link belongs to another part or occurs twice. Your draft has been kept."
        case .staleStatus:
            "This part's status changed. Cancel and reopen the editor before saving. Your draft has been kept."
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
            if let existing, draft.originalStatus != existing.record.status {
                throw PartError.staleStatus
            }
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            var record = try draft.record(
                id: existing?.id ?? dependencies.makeID(), jobID: jobID,
                existing: existing?.record,
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
            var hasRecordedOrder =
                existing?.record.orderedAt != nil
                || existing?.record.supplierSnapshot != nil
            if let existing, draft.status == .ordered, !hasRecordedOrder {
                hasRecordedOrder = try PartQueries.hasRecordedOrder(existing.id, for: jobID, in: db)
            }
            Self.applyProcurement(
                draft, to: &record, existing: existing?.record, links: links,
                hasRecordedOrder: hasRecordedOrder, now: now)
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
            for link in links {
                try link.save(db)
                try SearchKey.refresh(link.id, table: .partLink, in: db)
            }
            try SearchKey.refresh(record.id, table: .partRequirement, in: db)
            if let existing {
                if existing.record.status != record.status
                    || existing.record.orderReference != record.orderReference
                {
                    try ActivityQueries.insert(
                        jobID: jobID, kind: .partStatusChanged,
                        prior: .part(PartProcurementValue(part: existing.record)),
                        next: .part(PartProcurementValue(part: record)),
                        in: db, dependencies: dependencies)
                }
            } else if record.status == .arrived {
                try ActivityQueries.insert(
                    jobID: jobID, kind: .partStatusChanged,
                    prior: .part(PartProcurementValue(part: record, isNew: true)),
                    next: .part(PartProcurementValue(part: record)),
                    in: db, dependencies: dependencies)
            }
            return result
        }
    }

    private static func applyProcurement(
        _ draft: PartDraft, to record: inout PartRecord, existing: PartRecord?,
        links: [PartLink], hasRecordedOrder: Bool, now: Date
    ) {
        if draft.status == .ordered {
            record.orderReference = JobDraft.optional(draft.orderReference)
        }
        guard existing?.status != draft.status else { return }
        record.status = draft.status
        record.statusReason = nil
        if draft.needsReason { record.statusReason = JobDraft.optional(draft.statusReason) }
        record.cancelledAt = nil
        switch draft.status {
        case .needed:
            record.orderedAt = nil
            record.arrivedAt = nil
            record.installedAt = nil
            record.supplierSnapshot = nil
            record.orderReference = nil
        case .ordered:
            record.orderedAt = record.orderedAt ?? now
            record.arrivedAt = nil
            record.installedAt = nil
            if !hasRecordedOrder {
                record.supplierSnapshot = links.first(where: \.isSelected).map(
                    PartSupplierSnapshot.init)
            }
        case .arrived:
            record.arrivedAt = record.arrivedAt ?? now
            record.installedAt = nil
        case .installed:
            record.arrivedAt = record.arrivedAt ?? now
            record.installedAt = now
        case .cancelled:
            record.orderedAt = nil
            record.arrivedAt = nil
            record.installedAt = nil
            record.cancelledAt = now
        }
    }

    @MainActor
    func open(_ link: PartLink) throws {
        guard let url = ReferenceDraft.parsedURL(link.url) else { throw ReferenceError.invalidURL }
        guard openBrowser(url) else { throw ReferenceError.browserUnavailable }
    }
}
