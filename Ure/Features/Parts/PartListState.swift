import Foundation
import GRDB
import Observation

// The three groups of the Parts list, in the order they show.
nonisolated enum PartListGroup: CaseIterable, Sendable {
    case toBuy
    case ordered
    case inHand

    var title: String {
        switch self {
        case .toBuy: "To buy"
        case .ordered: "Ordered"
        case .inHand: "In hand"
        }
    }

    var stage: PartStage {
        switch self {
        case .toBuy: .needed
        case .ordered: .ordered
        case .inHand: .inHand
        }
    }
}

// The Parts list: the parts still to buy, ordered and in hand, on open jobs or in the drawer.
// Fitted parts stay on their job's page.
@Observable
final class PartListState {
    private let coordinator: LibraryCoordinator
    private(set) var rows: [PartListRow] = []
    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var observationRevision = 0
    var searchText = ""

    init(coordinator: LibraryCoordinator) { self.coordinator = coordinator }

    var filteredRows: [PartListRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            SearchKey.matches(
                [
                    row.part.name, row.part.description, row.part.notes, row.job?.title,
                    row.watch?.name, row.watch?.brand, row.watch?.model,
                ], query: query)
        }
    }

    func rows(in group: PartListGroup) -> [PartListRow] {
        filteredRows.filter { $0.part.stage == group.stage }
    }

    func contains(_ id: UUID?) -> Bool { rows.contains { $0.id == id } }

    // The parts still to buy. The sidebar counts them.
    var toBuyCount: Int { rows.filter { $0.part.stage == .needed }.count }

    // The toolbar's subtitle, such as "2 to buy · 2 ordered".
    var subtitle: String {
        let ordered = rows.filter { $0.part.stage == .ordered }.count
        if toBuyCount == 0, ordered == 0 { return "Nothing to buy" }
        return "\(toBuyCount) to buy · \(ordered) ordered"
    }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            let values = try await coordinator.partListValues()
            for try await rows in values {
                try Task.checkCancellation()
                self.rows = rows
                isLoading = false
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    func retry() { observationRevision += 1 }

    func clearSearch() { searchText = "" }
}

// How the Parts list words a part, as on "3 Parts": its name with its quantity when it is more
// than one, such as "Crystal gasket × 2", and a line with its job's watch, or "Spare" for a part
// in the drawer, and the day an ordered part was ordered, such as "Spare · 31 Oct".
enum PartListWording {
    static func title(of row: PartListRow) -> String {
        guard row.part.quantity > 1 else { return row.part.name }
        return "\(row.part.name) × \(row.part.quantity)"
    }

    // An ordered part names the supplier it was bought from instead of its watch, such as
    // "Cousins UK · 15 Oct", and a spare keeps "Spare" first, such as "Spare · Esslinger · 31 Oct".
    static func detail(of row: PartListRow, now: Date = .now) -> String {
        var parts: [String] = []
        let supplier = row.part.stage == .ordered ? row.part.purchase?.supplier : nil
        if row.part.isSpare {
            parts.append("Spare")
        } else if supplier == nil, let watch = row.watch {
            parts.append(watch.name)
        } else if supplier == nil {
            parts.append(row.job?.title ?? "No watch yet")
        }
        if let supplier { parts.append(supplier) }
        if row.part.stage == .ordered, let ordered = row.part.orderedAt {
            parts.append(PartWording.shortDay(ordered, now: now))
        }
        return parts.joined(separator: " · ")
    }

    // What a part costs on the right of its row: what you paid, or for a part to buy the lowest
    // price with shipping, such as "from €21.40", or "No options". A quiet text is one you have
    // not paid.
    static func price(
        of part: PartRecord, options: [PartOption], rates: ExchangeRates,
        locale: Locale = .current
    ) -> (text: String, isQuiet: Bool)? {
        if let paid = part.purchase?.paid { return (paid.formatted(locale: locale), false) }
        guard part.stage == .needed else { return nil }
        if options.isEmpty { return ("No options", true) }
        if let lowest = PartPricing.lowestPrice(options, rates: rates) {
            return ("from \(lowest.money.formatted(locale: locale))", true)
        }
        return (options.count == 1 ? "1 option" : "\(options.count) options", true)
    }
}
