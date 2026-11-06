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

// A save of a job's checklist: the steps it had, and the steps it has now.
nonisolated struct ChecklistRevision: Equatable, Sendable {
    let before: [ChecklistStep]
    let after: [ChecklistStepRecord]

    var changed: Bool { before != after.map(ChecklistStep.init(record:)) }
}

nonisolated struct ChecklistService: Sendable {
    let coordinator: LibraryCoordinator

    // Makes the job's saved checklist the steps given, in their order. Steps without text are
    // left out. A step that did not change keeps its edit time. The job can be Done, but not
    // archived.
    @discardableResult
    func save(_ steps: [ChecklistStep], for jobID: UUID) async throws -> ChecklistRevision {
        try await coordinator.mutate { db, _, dependencies in
            _ = try JobService.requireJob(jobID, in: db)
            let now = Date(timeIntervalSince1970: dependencies.now().timeIntervalSince1970)
            let kept = steps.filter { !$0.isBlank }.map(\.saved)
            guard Set(kept.map(\.id)).count == kept.count else {
                throw ChecklistError.stepMismatch
            }
            let existing = try ChecklistQueries.ordered(for: jobID, in: db)
            let before = existing.map(ChecklistStep.init(record:))
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
            return ChecklistRevision(
                before: before, after: try ChecklistQueries.ordered(for: jobID, in: db))
        }
    }
}
