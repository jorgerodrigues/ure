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

// How the Parts list words a part's line: its job's watch and title, such as "Grandfather's
// Seamaster · Full service", or "Spare" for a part in the drawer, with its quantity when it is
// more than one.
nonisolated enum PartListWording {
    static func detail(of row: PartListRow) -> String {
        var parts: [String] = []
        if row.part.isSpare {
            parts.append("Spare")
        } else {
            parts.append(row.watch?.name ?? "No watch yet")
            if let job = row.job { parts.append(job.title) }
        }
        if row.part.quantity > 1 { parts.append("× \(row.part.quantity)") }
        return parts.joined(separator: " · ")
    }
}
