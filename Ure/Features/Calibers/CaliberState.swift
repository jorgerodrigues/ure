import Foundation
import GRDB
import Observation

// The calibers in the library and the page you write each one on. A caliber page has no
// draft: each fact saves on its own as you type, like notes. Every change goes through the
// library's edit queue.
@Observable
final class CaliberState {
    static let unsavedFacts = "A fact on this page did not save. Correct it or undo it first."

    let queue: EditQueue
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    private(set) var calibers: [CaliberRecord] = []
    private(set) var selectedID: UUID?
    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var facts: [UUID: CaliberFacts] = [:]
    // A caliber just made with ⌘N. Its page puts the cursor in its name.
    private(set) var nameToFocus: UUID?
    var searchText = ""
    // Whether the Archived section at the end of the list is open.
    var showsArchived = false

    init(
        queue: EditQueue, locale: Locale = .autoupdatingCurrent,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.queue = queue
        self.locale = locale
        self.pause = pause
        queue.listen { [weak self] change, byUndo in
            guard case .caliber(let record) = change else { return }
            self?.adopt(record, force: byUndo)
        }
    }

    // A caliber change, such as ⌘N or an archive, is still saving.
    var isSaving: Bool { queue.isBusy(.calibers) }
    var saveError: String? { queue.failure(in: .calibers) }

    var selectedCaliber: CaliberRecord? { calibers.first { $0.id == selectedID } }

    func caliber(_ id: UUID?) -> CaliberRecord? {
        guard let id else { return nil }
        return calibers.first { $0.id == id }
    }

    func facts(for id: UUID) -> CaliberFacts? { facts[id] }

    // Active calibers by maker and name, as the list shows them, such as "ETA 2824-2".
    var filteredCalibers: [CaliberRecord] { matching(calibers.filter { $0.archivedAt == nil }) }

    // Archived calibers that match the list's search. They fold away at the end of the list.
    var archivedCalibers: [CaliberRecord] { matching(calibers.filter { $0.archivedAt != nil }) }

    // Every caliber that is not archived, in list order, whatever the list's search.
    var activeCalibers: [CaliberRecord] {
        calibers.filter { $0.archivedAt == nil }.sorted(by: Self.isInListOrder)
    }

    var activeCount: Int { calibers.filter { $0.archivedAt == nil }.count }
    var archivedCount: Int { calibers.count - activeCount }

    private func matching(_ records: [CaliberRecord]) -> [CaliberRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordered = records.sorted(by: Self.isInListOrder)
        if query.isEmpty { return ordered }
        return ordered.filter { caliber in
            SearchKey.matches([caliber.designation, caliber.manufacturer], query: query)
        }
    }

    private static func isInListOrder(_ lhs: CaliberRecord, _ rhs: CaliberRecord) -> Bool {
        let order = lhs.title.localizedStandardCompare(rhs.title)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    // Makers already in the library, offered as you type a maker, with how many calibers each
    // has.
    var makers: [FactSuggestion] {
        let counts = Dictionary(grouping: calibers.compactMap(\.manufacturer)) { $0 }
            .mapValues(\.count)
        return counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map {
            maker in
            let count = counts[maker] ?? 0
            return FactSuggestion(
                text: maker, detail: count == 1 ? "1 caliber" : "\(count) calibers")
        }
    }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            let values = try await queue.coordinator.caliberValues()
            for try await records in values {
                apply(records)
                isLoading = false
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    // Selecting an archived caliber opens the Archived section, so the list shows the selection.
    func select(_ id: UUID?) {
        selectedID = id
        if selectedCaliber?.archivedAt != nil { showsArchived = true }
    }

    // ⌘N makes a caliber and puts the cursor in its name.
    func createCommand() { create() }

    @discardableResult
    func create() -> EditTicket? {
        guard !isSaving else { return nil }
        return queue.submit(.caliber(.create), in: .calibers) { [weak self] result in
            guard let self else { return }
            for case .caliber(let record) in result.changes {
                searchText = ""
                selectedID = record.id
                nameToFocus = record.id
            }
        }
    }

    func nameFocused() { nameToFocus = nil }

    func toggleArchiveCommand(undoManager: UndoManager?) { toggleArchive(undoManager: undoManager) }

    // Archives the selected caliber, or unarchives it. Undo puts it back as it was. Typing on
    // the page saves first. A fact that does not save stops the archive, because an archived
    // caliber's facts can't be corrected.
    @discardableResult
    func toggleArchive(undoManager: UndoManager? = nil) -> EditTicket? {
        guard !isSaving, let record = selectedCaliber else { return nil }
        let id = record.id
        let archived = record.archivedAt == nil
        queue.flushTyping()
        facts[id]?.saveFailedText()
        if archived, facts[id]?.hasRefusedText == true {
            queue.report(Self.unsavedFacts, in: .calibers)
            return nil
        }
        return queue.submit(
            .caliber(.archive(id, archived)), in: .calibers,
            undo: archived ? "Archive Caliber" : "Unarchive Caliber", undoManager: undoManager,
            requires: EditCheck { [weak self] in
                archived && self?.facts[id]?.hasUnsavedText == true ? Self.unsavedFacts : nil
            })
    }

    private func adopt(_ record: CaliberRecord, force: Bool) {
        var records = calibers
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        apply(records, forcing: force ? record.id : nil)
        if record.archivedAt != nil, record.id == selectedID { showsArchived = true }
    }

    // Undo and Redo of a caliber's fact show the stored value also in a field with the cursor.
    private func apply(_ records: [CaliberRecord], forcing forced: UUID? = nil) {
        calibers = records
        for record in records {
            if let existing = facts[record.id] {
                existing.refresh(record, locale: locale, force: record.id == forced)
            } else {
                facts[record.id] = CaliberFacts(
                    caliber: record, queue: queue, locale: locale,
                    makers: { [weak self] in self?.makers ?? [] }, pause: pause)
            }
        }
    }
}
