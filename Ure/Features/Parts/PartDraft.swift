import Foundation

nonisolated enum PartField: Hashable {
    case description
    case quantity
    case compatibilityNote
    case link(UUID)
    case status
    case statusReason
    case onHand
}

nonisolated struct PartValidationError: LocalizedError {
    let fields: [PartField: String]
    var errorDescription: String? { "Check the marked fields. Your draft has been kept." }
}

nonisolated struct PartLinkDraft: Equatable, Identifiable, Sendable {
    let id: UUID
    var url: String

    init(id: UUID = UUID(), url: String = "") {
        self.id = id
        self.url = url
    }

    init(link: PartLink) {
        id = link.id
        url = link.url
    }
}

nonisolated struct PartDraft: Equatable, Sendable {
    var description = ""
    var quantity = "1"
    var manufacturerReference = ""
    var compatibility: PartCompatibility = .unchecked
    var compatibilityNote = ""
    var links: [PartLinkDraft] = []
    private(set) var originalStatus: PartStatus?
    var status: PartStatus = .needed
    var statusReason = ""
    var orderReference = ""
    var confirmsOnHand = false

    init() {}

    init(part: PartRequirement) {
        description = part.record.description
        quantity = String(part.record.quantity)
        manufacturerReference = part.record.manufacturerReference ?? ""
        compatibility = part.record.compatibility
        compatibilityNote = part.record.compatibilityNote ?? ""
        links = part.links.map(PartLinkDraft.init)
        originalStatus = part.record.status
        status = part.record.status
        orderReference = part.record.orderReference ?? ""
    }

    var needsReason: Bool {
        guard let originalStatus else { return false }
        return status.requiresReason(from: originalStatus)
    }

    var needsOnHandConfirmation: Bool {
        status == .installed && originalStatus != .arrived && originalStatus != .installed
    }

    func record(id: UUID, jobID: UUID, existing: PartRecord?, createdAt: Date, updatedAt: Date)
        throws
        -> PartRecord
    {
        var fields: [PartField: String] = [:]
        if existing == nil && status != .needed && status != .arrived {
            fields[.status] =
                "Start at Needed or Arrived. Save the part before ordering or installing."
        }
        if needsReason && JobDraft.optional(statusReason) == nil {
            fields[.statusReason] = "Enter a reason for this correction or cancellation."
        }
        if needsOnHandConfirmation && !confirmsOnHand {
            fields[.onHand] = "Confirm that the complete unit or lot is on hand."
        }
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty { fields[.description] = "Enter a part description." }
        let quantityText = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let quantity = Int(quantityText)
        if quantityText.isEmpty || quantityText.contains(where: { !$0.isASCII || !$0.isNumber })
            || (quantity ?? 0) <= 0
        {
            fields[.quantity] = "Enter a positive whole-number quantity."
        }
        if compatibility == .confirmed && JobDraft.optional(compatibilityNote) == nil {
            fields[.compatibilityNote] = "Enter evidence for confirmed compatibility."
        }
        for link in links where ReferenceDraft.parsedURL(link.url) == nil {
            fields[.link(link.id)] = "Enter a complete HTTP or HTTPS URL with a host."
        }
        guard fields.isEmpty, let quantity else { throw PartValidationError(fields: fields) }
        return PartRecord(
            id: id, jobID: jobID, description: description, quantity: quantity,
            manufacturerReference: JobDraft.optional(manufacturerReference),
            compatibility: compatibility, compatibilityNote: JobDraft.optional(compatibilityNote),
            status: existing?.status ?? .needed, orderedAt: existing?.orderedAt,
            arrivedAt: existing?.arrivedAt, installedAt: existing?.installedAt,
            cancelledAt: existing?.cancelledAt, orderReference: existing?.orderReference,
            statusReason: existing?.statusReason,
            createdAt: createdAt, updatedAt: updatedAt)
    }
}
