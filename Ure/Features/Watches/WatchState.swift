import Foundation
import GRDB
import Observation

// The watches in the library and the page you write each one on. A watch page has no draft:
// each fact saves on its own as you type, like notes. Any watch can be archived, and Undo
// brings it back.
@Observable
final class WatchState {
    private let service: WatchService
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    @ObservationIgnored private let archiving = ChangeUndo<Bool>()
    private(set) var watches: [WatchRecord] = []
    private(set) var selectedID: UUID?
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var facts: [UUID: WatchFacts] = [:]
    // A watch just made with ⌘N. Its page puts the cursor in its name.
    private(set) var nameToFocus: UUID?
    var searchText = ""
    // Whether the Archived section at the end of the list is open.
    var showsArchived = false

    init(
        service: WatchService, locale: Locale = .autoupdatingCurrent,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.locale = locale
        self.pause = pause
    }

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

    var hasUnsavedFacts: Bool { facts.values.contains { $0.hasUnsavedChanges } }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            let values = try await service.coordinator.watchValues()
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
    func createCommand() { Task { await create() } }

    @discardableResult
    func create() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let record = try await service.create()
            if !watches.contains(where: { $0.id == record.id }) {
                apply(watches + [record])
            }
            searchText = ""
            selectedID = record.id
            nameToFocus = record.id
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    func nameFocused() { nameToFocus = nil }

    func toggleArchiveCommand(undoManager: UndoManager?) {
        Task { await toggleArchive(undoManager: undoManager) }
    }

    // Archives the selected watch, or unarchives it. Undo puts it back as it was.
    @discardableResult
    func toggleArchive(undoManager: UndoManager? = nil) async -> Bool {
        guard !isSaving, let record = selectedWatch else { return false }
        let id = record.id
        let archived = record.archivedAt == nil
        let write: ChangeUndo<Bool>.Write = { [weak self] archived in
            await self?.writeArchive(id, archived: archived) ?? false
        }
        guard await archiving.perform(archived, write: write) else { return false }
        archiving.registerUndo(
            setting: !archived, redoing: archived,
            actionName: archived ? "Archive Watch" : "Unarchive Watch",
            undoManager: undoManager, write: write)
        return true
    }

    // Waits for an archive change that Undo or Redo started.
    func waitForArchiveChanges() async { await archiving.wait() }

    func saveFactsNow() {
        for field in unsavedFields { field.saveNow() }
    }

    func saveAllFacts() async -> Bool {
        var succeeded = true
        for field in unsavedFields {
            if await !field.flush() { succeeded = false }
        }
        return succeeded
    }

    func discardUndo() {
        for facts in facts.values {
            for field in facts.all { field.discardUndo() }
        }
        archiving.discardUndo()
    }

    private var unsavedFields: [FactField] {
        facts.values.flatMap(\.all).filter(\.hasUnsavedChanges)
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

    // Facts still saving finish first. A fact that does not save stops the archive, because an
    // archived watch's facts can't be corrected.
    private func writeArchive(_ id: UUID, archived: Bool) async -> Bool {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        if archived, let facts = facts[id] {
            for field in facts.all where field.hasUnsavedChanges {
                guard await field.flush() else {
                    saveError = "A fact on this page did not save. Correct it or undo it first."
                    return false
                }
            }
        }
        do {
            let saved = try await ArchiveService(coordinator: service.coordinator).setWatch(
                id, archived: archived)
            if let index = watches.firstIndex(where: { $0.id == saved.id }) {
                watches[index] = saved
            }
            if saved.archivedAt != nil, saved.id == selectedID { showsArchived = true }
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func apply(_ records: [WatchRecord]) {
        watches = records
        for record in records {
            if let existing = facts[record.id] {
                existing.refresh(record, locale: locale)
            } else {
                facts[record.id] = WatchFacts(
                    watch: record, service: service, locale: locale,
                    brands: { [weak self] in self?.brands ?? [] }, pause: pause)
            }
        }
    }
}
