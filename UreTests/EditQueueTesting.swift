import Foundation
import Synchronization

@testable import Ure

// What a submitted edit led to, read once it has run.
extension EditTicket {
    var part: PartRecord? {
        get async {
            for case .part(let part) in await value.changes { return part }
            return nil
        }
    }

    var job: JobRecord? {
        get async {
            for case .job(let job) in await value.changes { return job }
            return nil
        }
    }

    var watch: WatchRecord? {
        get async {
            for case .watch(let watch) in await value.changes { return watch }
            return nil
        }
    }

    var caliber: CaliberRecord? {
        get async {
            for case .caliber(let caliber) in await value.changes { return caliber }
            return nil
        }
    }

    var message: String? {
        get async { await value.error?.localizedDescription }
    }
}

extension Optional where Wrapped == EditTicket {
    // Whether an edit was submitted and saved. Nothing submitted is not saved.
    var didSave: Bool {
        get async {
            guard let ticket = self else { return false }
            return await ticket.saved
        }
    }
}

// Every feature's state on one library edit queue, as a window's session has them.
enum EditingFixture {
    static func make(
        _ coordinator: LibraryCoordinator,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> WorkshopEditing {
        let queue = EditQueue(coordinator: coordinator)
        return WorkshopEditing(
            queue: queue, watches: WatchState(queue: queue, pause: pause),
            calibers: CaliberState(queue: queue, pause: pause),
            jobs: JobState(queue: queue, pause: pause),
            notes: RecordNotesState(queue: queue, pause: pause),
            material: MaterialState(
                service: MaterialService(coordinator: coordinator, openBrowser: { _ in false }),
                queue: queue, pause: pause),
            checklist: ChecklistState(queue: queue, pause: pause),
            parts: PartState(
                service: PartService(coordinator: coordinator, openBrowser: { _ in false }),
                queue: queue, pause: pause))
    }
}

// A write that holds the library until the test lets it go, as a slow write or a backup export
// does.
nonisolated final class LibraryHold: Sendable {
    private let started = Mutex(false)
    private let gate = DispatchSemaphore(value: 0)

    var hasStarted: Bool { started.withLock { $0 } }

    func hold() {
        started.withLock { $0 = true }
        gate.wait()
    }

    func release() { gate.signal() }

    // Holds the library from a write of its own, and returns once the hold has begun.
    static func start(on coordinator: LibraryCoordinator) async throws -> (
        LibraryHold, Task<Void, any Error>
    ) {
        let hold = LibraryHold()
        let holding = Task.detached { try await coordinator.mutate { _, _, _ in hold.hold() } }
        for _ in 0..<500 where !hold.hasStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (hold, holding)
    }
}
