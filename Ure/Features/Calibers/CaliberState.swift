import Foundation
import GRDB
import Observation

// The calibers in the library and the page you write each one on. A caliber page has no
// draft: each fact saves on its own as you type, like notes.
@Observable
final class CaliberState {
    private let service: CaliberService
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    @ObservationIgnored private let archiving = ChangeUndo<Bool>()
    private(set) var calibers: [CaliberRecord] = []
    private(set) var selectedID: UUID?
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var facts: [UUID: CaliberFacts] = [:]
    // A caliber just made with ⌘N. Its page puts the cursor in its name.
    private(set) var nameToFocus: UUID?
    var searchText = ""
    // Whether the Archived section at the end of the list is open.
    var showsArchived = false

    init(
        service: CaliberService, locale: Locale = .autoupdatingCurrent,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.locale = locale
        self.pause = pause
    }

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

    var hasUnsavedFacts: Bool { facts.values.contains { $0.hasUnsavedChanges } }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            let values = try await service.coordinator.caliberValues()
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
    func createCommand() { Task { await create() } }

    @discardableResult
    func create() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let record = try await service.create()
            if !calibers.contains(where: { $0.id == record.id }) {
                apply(calibers + [record])
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

    // Archives the selected caliber, or unarchives it. Undo puts it back as it was.
    @discardableResult
    func toggleArchive(undoManager: UndoManager? = nil) async -> Bool {
        guard !isSaving, let record = selectedCaliber else { return false }
        let id = record.id
        let archived = record.archivedAt == nil
        let write: ChangeUndo<Bool>.Write = { [weak self] archived in
            await self?.writeArchive(id, archived: archived) ?? false
        }
        guard await archiving.perform(archived, write: write) else { return false }
        archiving.registerUndo(
            setting: !archived, redoing: archived,
            actionName: archived ? "Archive Caliber" : "Unarchive Caliber",
            undoManager: undoManager, write: write)
        return true
    }

    // Waits for an archive change that Undo or Redo started.
    func waitForArchiveChanges() async { await archiving.wait() }

    // Facts still saving finish first. A fact that does not save stops the archive, because
    // an archived caliber's facts can't be corrected.
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
            let saved = try await ArchiveService(coordinator: service.coordinator).setCaliber(
                id, archived: archived)
            if let index = calibers.firstIndex(where: { $0.id == saved.id }) {
                calibers[index] = saved
            }
            if saved.archivedAt != nil, saved.id == selectedID { showsArchived = true }
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

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

    private func apply(_ records: [CaliberRecord]) {
        calibers = records
        for record in records {
            if let existing = facts[record.id] {
                existing.refresh(record, locale: locale)
            } else {
                facts[record.id] = CaliberFacts(
                    caliber: record, service: service, locale: locale,
                    makers: { [weak self] in self?.makers ?? [] }, pause: pause)
            }
        }
    }
}
