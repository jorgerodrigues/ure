import Foundation
import GRDB
import Observation

// The watches in the library and the page you write each one on. A watch page has no draft:
// each fact saves on its own as you type, like notes. Any watch can be archived, and Undo
// brings it back. Every change goes through the library's edit queue.
@Observable
final class WatchState {
    private let queue: EditQueue
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    private(set) var watches: [WatchRecord] = []
    private(set) var selectedID: UUID?
    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var facts: [UUID: WatchFacts] = [:]
    // A watch just made with ⌘N. Its page puts the cursor in its name.
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
            guard case .watch(let record) = change else { return }
            self?.adopt(record, force: byUndo)
        }
    }

    // A watch change, such as ⌘N or an archive, is still saving.
    var isSaving: Bool { queue.isBusy(.watches) }
    var saveError: String? { queue.failure(in: .watches) }

    var selectedWatch: WatchRecord? { watches.first { $0.id == selectedID } }

    func facts(for id: UUID) -> WatchFacts? { facts[id] }

    // Watches that are not archived and match the list's search, in order of name.
    var filteredWatches: [WatchRecord] { matching(watches.filter { $0.archivedAt == nil }) }

    // Archived watches that match the list's search. They fold away at the end of the list.
    var archivedWatches: [WatchRecord] { matching(watches.filter { $0.archivedAt != nil }) }

    var activeCount: Int { watches.filter { $0.archivedAt == nil }.count }
    var archivedCount: Int { watches.count - activeCount }

    // Brands already in the library, offered as you type a brand, with how many watches each
    // has.
    var brands: [FactSuggestion] {
        let counts = Dictionary(grouping: watches.compactMap(\.brand)) { $0 }.mapValues(\.count)
        return counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map {
            brand in
            let count = counts[brand] ?? 0
            return FactSuggestion(text: brand, detail: count == 1 ? "1 watch" : "\(count) watches")
        }
    }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            let values = try await queue.coordinator.watchValues()
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

    // Selecting an archived watch opens the Archived section, so the list shows the selection.
    func select(_ id: UUID?) {
        selectedID = id
        if selectedWatch?.archivedAt != nil { showsArchived = true }
    }

    // ⌘N makes a watch and puts the cursor in its name.
    func createCommand() { create() }

    @discardableResult
    func create() -> EditTicket? {
        guard !isSaving else { return nil }
        return queue.submit(.watch(.create), in: .watches) { [weak self] result in
            guard let self else { return }
            for case .watch(let record) in result.changes {
                searchText = ""
                selectedID = record.id
                nameToFocus = record.id
            }
        }
    }

    func nameFocused() { nameToFocus = nil }

    func toggleArchiveCommand(undoManager: UndoManager?) { toggleArchive(undoManager: undoManager) }

    // Archives the selected watch, or unarchives it. Undo puts it back as it was. Typing on the
    // page saves first. A fact that does not save stops the archive, because an archived
    // watch's facts can't be corrected.
    @discardableResult
    func toggleArchive(undoManager: UndoManager? = nil) -> EditTicket? {
        guard !isSaving, let record = selectedWatch else { return nil }
        let id = record.id
        let archived = record.archivedAt == nil
        queue.flushTyping()
        if archived, facts[id]?.hasUnsavedText == true {
            queue.report(CaliberState.unsavedFacts, in: .watches)
            return nil
        }
        return queue.submit(
            .watch(.archive(id, archived)), in: .watches,
            undo: archived ? "Archive Watch" : "Unarchive Watch", undoManager: undoManager,
            requires: EditCheck { [weak self] in
                archived && self?.facts[id]?.hasUnsavedText == true
                    ? CaliberState.unsavedFacts : nil
            })
    }

    private func matching(_ records: [WatchRecord]) -> [WatchRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return records }
        return records.filter { watch in
            SearchKey.matches(
                [
                    watch.name, watch.brand, watch.model, watch.caseReference, watch.serial,
                    watch.approximateYear, watch.owner, watch.contact,
                ], query: query)
        }
    }

    private func adopt(_ record: WatchRecord, force: Bool) {
        var records = watches
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        apply(records, forcing: force ? record.id : nil)
        if record.archivedAt != nil, record.id == selectedID { showsArchived = true }
    }

    // Undo and Redo of a watch's fact show the stored value also in a field with the cursor.
    private func apply(_ records: [WatchRecord], forcing forced: UUID? = nil) {
        watches = records
        for record in records {
            if let existing = facts[record.id] {
                existing.refresh(record, locale: locale, force: record.id == forced)
            } else {
                facts[record.id] = WatchFacts(
                    watch: record, queue: queue, locale: locale,
                    brands: { [weak self] in self?.brands ?? [] }, pause: pause)
            }
        }
    }
}
