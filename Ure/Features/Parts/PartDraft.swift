import Foundation

nonisolated enum PartField: Hashable {
    case description
    case quantity
    case compatibilityNote
    case link(UUID)
    case price(UUID)
    case currency(UUID)
    case selectedLink
}

nonisolated struct PartValidationError: LocalizedError {
    let fields: [PartField: String]
    var errorDescription: String? { "Check the marked fields. Your draft has been kept." }
}

nonisolated struct PartLinkDraft: Equatable, Identifiable, Sendable {
    let id: UUID
    var url: String
    var title = ""
    var supplierName = ""
    var supplierStockCode = ""
    var price = ""
    var currency = ""
    var notes = ""

    init(id: UUID = UUID(), url: String = "") {
        self.id = id
        self.url = url
    }

    init(link: PartLink) {
        id = link.id
        url = link.url
        title = link.title ?? ""
        supplierName = link.supplierName ?? ""
        supplierStockCode = link.supplierStockCode ?? ""
        price = link.price ?? ""
        currency = link.currency ?? ""
        notes = link.notes ?? ""
    }

    static func isValidPrice(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return (1...2).contains(components.count)
            && components.allSatisfy { component in
                !component.isEmpty && component.allSatisfy { $0.isASCII && $0.isNumber }
            }
    }
}

nonisolated struct PartDraft: Equatable, Sendable {
    var description = ""
    var quantity = "1"
    var manufacturerReference = ""
    var compatibility: PartCompatibility = .unchecked
    var compatibilityNote = ""
    var links: [PartLinkDraft] = []
    var selectedLinkID: UUID?

    init() {}

    init(part: PartRequirement) {
        description = part.record.description
        quantity = String(part.record.quantity)
        manufacturerReference = part.record.manufacturerReference ?? ""
        compatibility = part.record.compatibility
        compatibilityNote = part.record.compatibilityNote ?? ""
        links = part.links.map(PartLinkDraft.init)
        selectedLinkID = part.selectedLink?.id
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
        for link in links {
            if ReferenceDraft.parsedURL(link.url) == nil {
                fields[.link(link.id)] = "Enter a complete HTTP or HTTPS URL with a host."
            }
            let price = JobDraft.optional(link.price)
            let currency = JobDraft.optional(link.currency)?.uppercased()
            if let price, !PartLinkDraft.isValidPrice(price) {
                fields[.price(link.id)] =
                    "Enter a non-negative price using digits and a decimal point."
            }
            if let currency {
                if !Locale.commonISOCurrencyCodes.contains(currency) {
                    fields[.currency(link.id)] = "Enter a valid currency code, such as DKK or EUR."
                }
            } else if price != nil {
                fields[.currency(link.id)] = "Enter the currency for this price."
            }
        }
        if let selectedLinkID, !links.contains(where: { $0.id == selectedLinkID }) {
            fields[.selectedLink] = "Choose an option saved with this part."
        }
        guard fields.isEmpty, let quantity else { throw PartValidationError(fields: fields) }
        return PartRecord(
            id: id, jobID: jobID, description: description, quantity: quantity,
            manufacturerReference: JobDraft.optional(manufacturerReference),
            compatibility: compatibility, compatibilityNote: JobDraft.optional(compatibilityNote),
            status: status, createdAt: createdAt, updatedAt: updatedAt)
    }
}
