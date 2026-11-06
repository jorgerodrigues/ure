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

// One change to a job's checklist, applied to the steps the library holds when its turn comes.
// A change to one step leaves the other steps as they are, so an Undo and a later change never
// overwrite each other.
nonisolated enum ChecklistOperation: Equatable, Sendable {
    // Gives a step its text, heading and tick where it is. A step the list does not have goes at
    // the end.
    case update(ChecklistStep)
    // Puts a step after another, or first when there is none, with its text, heading and tick.
    case place(ChecklistStep, after: UUID?)
    case delete(UUID)

    // The changes that make one list of saved steps another.
    static func changes(from old: [ChecklistStep], to new: [ChecklistStep]) -> [ChecklistOperation] {
        let newIDs = Set(new.map(\.id))
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        var operations = old.filter { !newIDs.contains($0.id) }.map { delete($0.id) }
        let remaining = old.filter { newIDs.contains($0.id) }
        var before: [UUID: UUID] = [:]
        for (index, step) in remaining.enumerated() where index > 0 {
            before[step.id] = remaining[index - 1].id
        }
        for (index, step) in new.enumerated() {
            let previous = index > 0 ? new[index - 1].id : nil
            if oldByID[step.id] == nil || before[step.id] != previous {
                operations.append(.place(step, after: previous))
            } else if oldByID[step.id] != step {
                operations.append(.update(step))
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
            let id = operation.stepID
            let index = list.firstIndex { $0.id == id }
            let old = index.map { list[$0] }
            let oldPrevious = index.flatMap { $0 > 0 ? list[$0 - 1].id : nil }
            let undo = old.map { .place($0, after: oldPrevious) } ?? ChecklistOperation.delete(id)
            let before = list
            switch operation {
            case .update(let step):
                if let index {
                    list[index] = step
                } else {
                    list.append(step)
                }
            case .place(let step, let after):
                if let index { list.remove(at: index) }
                if let after, let previous = list.firstIndex(where: { $0.id == after }) {
                    list.insert(step, at: previous + 1)
                } else if after == nil {
                    list.insert(step, at: 0)
                } else if let index {
                    list.insert(step, at: min(index, list.count))
                } else {
                    list.append(step)
                }
            case .delete:
                if let index { list.remove(at: index) }
            }
            if list != before { inverse.append(undo) }
        }
        return (list, inverse.reversed())
    }

    private var stepID: UUID {
        switch self {
        case .update(let step), .place(let step, _): step.id
        case .delete(let id): id
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
            let saved = operations.map(\.saved)
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
    // The change with its step as it is saved, without the spaces around its text. A step
    // whose text is gone is deleted.
    nonisolated fileprivate var saved: ChecklistOperation {
        switch self {
        case .update(let step):
            step.isBlank ? .delete(step.id) : .update(step.saved)
        case .place(let step, let after):
            step.isBlank ? .delete(step.id) : .place(step.saved, after: after)
        case .delete:
            self
        }
    }
}
