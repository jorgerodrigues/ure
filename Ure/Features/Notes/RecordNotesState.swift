import Foundation
import Observation

@Observable
final class RecordNotesState {
    private let service: RecordNotesService
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    private(set) var fields: [LibraryItemOwner: AutosaveField] = [:]
    private(set) var loadErrors: [LibraryItemOwner: String] = [:]

    init(
        service: RecordNotesService,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.pause = pause
    }

    var hasUnsavedChanges: Bool { fields.values.contains { $0.hasUnsavedChanges } }
    var isEditing: Bool { fields.values.contains { $0.isEditing } }

    func field(for owner: LibraryItemOwner) -> AutosaveField? { fields[owner] }

    func load(_ owner: LibraryItemOwner) async {
        loadErrors[owner] = nil
        do {
            let stored = try await service.text(for: owner)
            if let field = fields[owner] {
                field.refresh(stored)
            } else {
                fields[owner] = AutosaveField(
                    text: stored, actionName: "Notes",
                    save: { [service] text in try await service.save(text, for: owner) },
                    pause: pause)
            }
        } catch {
            if Task.isCancelled { return }
            loadErrors[owner] = error.localizedDescription
        }
    }

    func saveNow() {
        for field in fields.values where field.hasUnsavedChanges { field.saveNow() }
    }

    func saveAll() async -> Bool {
        var succeeded = true
        for field in fields.values where field.hasUnsavedChanges {
            if await !field.flush() { succeeded = false }
        }
        return succeeded
    }

    func discardUndo() {
        for field in fields.values { field.discardUndo() }
    }
}
