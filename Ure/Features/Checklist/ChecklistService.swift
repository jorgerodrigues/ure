import Foundation
import GRDB

// One line of a checklist as you type it: a step with a tick, or a heading. A step without text
// stays on screen while you type it and is never saved.
nonisolated struct ChecklistStep: Equatable, Identifiable, Sendable {
    let id: UUID
    var text: String
    var isHeading = false
    var isTicked = false

    init(id: UUID, text: String = "", isHeading: Bool = false, isTicked: Bool = false) {
        self.id = id
        self.text = text
        self.isHeading = isHeading
        self.isTicked = isTicked
    }

    init(record: ChecklistStepRecord) {
        id = record.id
        text = record.text
        isHeading = record.isHeading
        isTicked = record.isTicked
    }

    var isBlank: Bool { text.allSatisfy(\.isWhitespace) }

    // The step as it is saved: its text without the spaces around it, and no tick on a heading.
    var saved: ChecklistStep {
        ChecklistStep(
            id: id, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            isHeading: isHeading, isTicked: isTicked && !isHeading)
    }
}

// How far a checklist is, such as "6 of 10 done". Headings and steps without text do not count.
nonisolated struct ChecklistProgress: Equatable, Sendable {
    let doneCount: Int
    let stepCount: Int

    init(_ steps: [ChecklistStep]) {
        let counted = steps.filter { !$0.isHeading && !$0.isBlank }
        stepCount = counted.count
        doneCount = counted.filter(\.isTicked).count
    }

    init(records: [ChecklistStepRecord]) {
        self.init(records.map(ChecklistStep.init(record:)))
    }

    var fraction: Double {
        guard stepCount > 0 else { return 0 }
        return Double(doneCount) / Double(stepCount)
    }

    var summary: String {
        guard stepCount > 0 else { return "No steps yet" }
        return "\(doneCount) of \(stepCount) done"
    }

    var accessibilitySummary: String {
        guard stepCount > 0 else { return "No steps yet" }
        return "\(doneCount) of \(stepCount) steps done"
    }
}

nonisolated enum ChecklistError: LocalizedError, Equatable {
    case stepMismatch

    var errorDescription: String? {
        switch self {
        case .stepMismatch:
            "A step belongs to another job or is in the list twice. Your steps are still here."
        }
    }
}

// The properties of one step that a change gives it. A property left nil keeps what the step
// holds when the change runs.
nonisolated struct ChecklistStepUpdate: Equatable, Sendable {
    let id: UUID
    var text: String? = nil
    var isHeading: Bool? = nil
    var isTicked: Bool? = nil

    // The properties that differ between two versions of a step, as the later one has them.
    init?(from old: ChecklistStep, to new: ChecklistStep) {
        id = new.id
        if old.text != new.text { text = new.text }
        if old.isHeading != new.isHeading { isHeading = new.isHeading }
        if old.isTicked != new.isTicked { isTicked = new.isTicked }
        if text == nil, isHeading == nil, isTicked == nil { return nil }
    }

    init(id: UUID, text: String? = nil, isHeading: Bool? = nil, isTicked: Bool? = nil) {
        self.id = id
        self.text = text
        self.isHeading = isHeading
        self.isTicked = isTicked
    }

    // The step with these properties. A heading has no tick.
    func applied(to step: ChecklistStep) -> ChecklistStep {
        var changed = step
        if let text { changed.text = text }
        if let isHeading { changed.isHeading = isHeading }
        if let isTicked { changed.isTicked = isTicked }
        if changed.isHeading { changed.isTicked = false }
        return changed
    }
}

// One change to a job's checklist, applied to the steps the library holds when its turn comes.
// A change touches only the step and the properties it names, so an Undo and a later change
// never overwrite each other.
nonisolated enum ChecklistOperation: Equatable, Sendable {
    // Adds a step after another, or first when there is none. A step the list has already
    // takes the properties and the place.
    case insert(ChecklistStep, after: UUID?)
    // Moves a step after another, or first.
    case move(UUID, after: UUID?)
    case update(ChecklistStepUpdate)
    case delete(UUID)

    // The changes that make one list of saved steps another.
    static func changes(from old: [ChecklistStep], to new: [ChecklistStep]) -> [ChecklistOperation]
    {
        let newIDs = Set(new.map(\.id))
        var oldByID: [UUID: ChecklistStep] = [:]
        for step in old { oldByID[step.id] = step }
        var operations = old.filter { !newIDs.contains($0.id) }.map { delete($0.id) }
        let remaining = old.filter { newIDs.contains($0.id) }
        var before: [UUID: UUID] = [:]
        for (index, step) in remaining.enumerated() where index > 0 {
            before[step.id] = remaining[index - 1].id
        }
        for (index, step) in new.enumerated() {
            let previous = index > 0 ? new[index - 1].id : nil
            guard let saved = oldByID[step.id] else {
                operations.append(.insert(step, after: previous))
                continue
            }
            if before[step.id] != previous { operations.append(.move(step.id, after: previous)) }
            if let update = ChecklistStepUpdate(from: saved, to: step) {
                operations.append(.update(update))
            }
        }
        return operations
    }

    // Applies changes to a list of saved steps. The changes that undo them come back too, in
    // the order to apply them.
    static func applying(_ operations: [ChecklistOperation], to steps: [ChecklistStep])
        -> (steps: [ChecklistStep], inverse: [ChecklistOperation])
    {
        var list = steps
        var inverse: [ChecklistOperation] = []
        for operation in operations {
            let index = list.firstIndex { $0.id == operation.stepID }
            let old = index.map { list[$0] }
            let oldPrevious = index.flatMap { $0 > 0 ? list[$0 - 1].id : nil }
            switch operation {
            case .insert(let step, let after):
                guard let index, let old else {
                    insert(step, after: after, at: nil, in: &list)
                    inverse.append(.delete(step.id))
                    continue
                }
                list.remove(at: index)
                insert(step, after: after, at: index, in: &list)
                inverse.append(contentsOf: undo(of: old, previous: oldPrevious, in: list))
            case .move(_, let after):
                guard let index, let old else { continue }
                list.remove(at: index)
                insert(old, after: after, at: index, in: &list)
                inverse.append(contentsOf: undo(of: old, previous: oldPrevious, in: list))
            case .update(let update):
                guard let index, let old else { continue }
                list[index] = update.applied(to: old)
                if let back = ChecklistStepUpdate(from: list[index], to: old) {
                    inverse.append(.update(back))
                }
            case .delete:
                guard let index, let old else { continue }
                list.remove(at: index)
                inverse.append(.insert(old, after: oldPrevious))
            }
        }
        return (list, inverse.reversed())
    }

    // What puts a step back as it was and where it was, if a change moved it or changed it.
    private static func undo(of old: ChecklistStep, previous: UUID?, in list: [ChecklistStep])
        -> [ChecklistOperation]
    {
        guard let index = list.firstIndex(where: { $0.id == old.id }) else {
            return [.insert(old, after: previous)]
        }
        var operations: [ChecklistOperation] = []
        if let back = ChecklistStepUpdate(from: list[index], to: old) {
            operations.append(.update(back))
        }
        let now = index > 0 ? list[index - 1].id : nil
        if now != previous { operations.append(.move(old.id, after: previous)) }
        return operations
    }

    // Puts a step after another. When that step is gone, the step keeps the place it had, or
    // goes at the end.
    private static func insert(
        _ step: ChecklistStep, after: UUID?, at place: Int?, in list: inout [ChecklistStep]
    ) {
        if let after, let previous = list.firstIndex(where: { $0.id == after }) {
            list.insert(step, at: previous + 1)
        } else if after == nil {
            list.insert(step, at: 0)
        } else if let place {
            list.insert(step, at: min(place, list.count))
        } else {
            list.append(step)
        }
    }

    // The step the change is about.
    var stepID: UUID {
        switch self {
        case .insert(let step, _): step.id
        case .move(let id, _), .delete(let id): id
        case .update(let update): update.id
        }
    }
}

// What a job's checklist holds after changes, and the changes that undo them.
nonisolated struct ChecklistChange: Equatable, Sendable {
    let after: [ChecklistStepRecord]
    let inverse: [ChecklistOperation]
}

nonisolated struct ChecklistService: Sendable {
    let coordinator: LibraryCoordinator

    // Applies changes to the job's saved checklist, in one go. Steps without text are left out.
    // A step that did not change keeps its edit time. The job can be Done, but not archived.
    func apply(_ operations: [ChecklistOperation], for jobID: UUID) async throws
        -> ChecklistChange
    {
        try await coordinator.mutate { db, _, dependencies in
            _ = try JobService.requireJob(jobID, in: db)
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            let existing = try ChecklistQueries.ordered(for: jobID, in: db)
            let saved = operations.compactMap(\.saved)
            let applied = ChecklistOperation.applying(
                saved, to: existing.map(ChecklistStep.init(record:)))
            try Self.write(
                applied.steps.filter { !$0.isBlank }, for: jobID, over: existing, at: now, in: db)
            return ChecklistChange(
                after: try ChecklistQueries.ordered(for: jobID, in: db),
                inverse: applied.inverse)
        }
    }

    // Makes the job's saved steps these, in their order.
    private static func write(
        _ kept: [ChecklistStep], for jobID: UUID, over existing: [ChecklistStepRecord],
        at now: Date, in db: Database
    ) throws {
        guard Set(kept.map(\.id)).count == kept.count else {
            throw ChecklistError.stepMismatch
        }
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let keptIDs = Set(kept.map(\.id))
        for record in existing where !keptIDs.contains(record.id) {
            _ = try record.delete(db)
        }
        for (position, step) in kept.enumerated() {
            if var record = byID[step.id] {
                guard
                    record.position != position || record.text != step.text
                        || record.isHeading != step.isHeading
                        || record.isTicked != step.isTicked
                else { continue }
                if ChecklistStep(record: record) != step { record.updatedAt = now }
                record.position = position
                record.text = step.text
                record.isHeading = step.isHeading
                record.isTicked = step.isTicked
                try record.update(db)
            } else {
                guard
                    try Int.fetchOne(
                        db, sql: "SELECT 1 FROM checklistStep WHERE id = ?",
                        arguments: [step.id.uuidString]) == nil
                else { throw ChecklistError.stepMismatch }
                try ChecklistStepRecord(
                    id: step.id, jobID: jobID, position: position, text: step.text,
                    isHeading: step.isHeading, isTicked: step.isTicked, createdAt: now,
                    updatedAt: now
                ).insert(db)
            }
        }
    }
}

extension ChecklistOperation {
    // The change with its text as it is saved, without the spaces around it. A step whose text
    // is gone is deleted, and a new step without text is not added.
    nonisolated fileprivate var saved: ChecklistOperation? {
        switch self {
        case .insert(let step, let after):
            if step.isBlank { return nil }
            return .insert(step.saved, after: after)
        case .update(var update):
            if let text = update.text {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return .delete(update.id) }
                update.text = trimmed
            }
            return .update(update)
        case .move, .delete:
            return self
        }
    }
}
