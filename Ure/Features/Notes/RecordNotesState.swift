import Foundation
import Observation

// The notes of every record page. Each record's notes are one field that saves as you type, as
// an edit on the library's queue.
@Observable
final class RecordNotesState {
    private let service: RecordNotesService
    private let queue: EditQueue
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    private(set) var fields: [LibraryItemOwner: AutosaveField] = [:]
    private(set) var loadErrors: [LibraryItemOwner: String] = [:]

    init(
        queue: EditQueue,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        service = RecordNotesService(coordinator: queue.coordinator)
        self.queue = queue
        self.pause = pause
        queue.listen { [weak self] change, byUndo in
            guard case .notes(let owner, let text) = change else { return }
            self?.fields[owner]?.refresh(text, force: byUndo)
        }
    }

    var isEditing: Bool { fields.values.contains { $0.isEditing } }

    func field(for owner: LibraryItemOwner) -> AutosaveField? { fields[owner] }

    // What did not save in a record's notes: the field's own save, or an Undo of it.
    func saveError(for owner: LibraryItemOwner) -> String? {
        fields[owner]?.saveError ?? queue.failure(in: .notes(owner))
    }

    func load(_ owner: LibraryItemOwner) async {
        loadErrors[owner] = nil
        do {
            let stored = try await service.text(for: owner)
            if let field = fields[owner] {
                field.refresh(stored)
            } else {
                fields[owner] = AutosaveField(
                    text: stored, actionName: "Notes", queue: queue, scope: .notes(owner),
                    edit: { .notes(owner, $0) }, pause: pause)
            }
        } catch {
            if Task.isCancelled { return }
            loadErrors[owner] = error.localizedDescription
        }
    }
}
