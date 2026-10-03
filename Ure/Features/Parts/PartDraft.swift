import Foundation

nonisolated enum PartField: Hashable {
    case description
    case quantity
    case compatibilityNote
    case link(UUID)
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
}

nonisolated struct PartDraft: Equatable, Sendable {
    var description = ""
    var quantity = "1"
    var manufacturerReference = ""
    var compatibility: PartCompatibility = .unchecked
    var compatibilityNote = ""
    var links: [PartLinkDraft] = []

    init() {}

    init(part: PartRequirement) {
        description = part.record.description
        quantity = String(part.record.quantity)
        manufacturerReference = part.record.manufacturerReference ?? ""
        compatibility = part.record.compatibility
        compatibilityNote = part.record.compatibilityNote ?? ""
        links = part.links.map { PartLinkDraft(id: $0.id, url: $0.url) }
    }

    func record(id: UUID, jobID: UUID, status: PartStatus, createdAt: Date, updatedAt: Date) throws
        -> PartRecord
    {
        var fields: [PartField: String] = [:]
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
            status: status, createdAt: createdAt, updatedAt: updatedAt)
    }
}
