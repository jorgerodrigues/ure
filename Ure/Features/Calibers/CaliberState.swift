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

    var filteredCalibers: [CaliberRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = calibers.filter { $0.archivedAt == nil }
        if query.isEmpty { return active }
        return active.filter { caliber in
            SearchKey.matches([caliber.designation, caliber.manufacturer], query: query)
        }
    }

    // Makers already in the library, offered as you type a maker.
    var makers: [String] {
        Set(calibers.compactMap(\.manufacturer)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
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

    func select(_ id: UUID?) { selectedID = id }

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

    func toggleArchiveCommand() { Task { await toggleArchive() } }

    // Facts still saving finish first. A fact that does not save stops the archive, because
    // an archived caliber's facts can't be corrected.
    @discardableResult
    func toggleArchive() async -> Bool {
        guard !isSaving, let record = selectedCaliber else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        if record.archivedAt == nil, let facts = facts[record.id] {
            for field in facts.all where field.hasUnsavedChanges {
                guard await field.flush() else {
                    saveError = "A fact on this page did not save. Correct it or undo it first."
                    return false
                }
            }
        }
        do {
            let saved = try await ArchiveService(coordinator: service.coordinator).setCaliber(
                record.id, archived: record.archivedAt == nil)
            if let index = calibers.firstIndex(where: { $0.id == saved.id }) {
                calibers[index] = saved
            }
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
