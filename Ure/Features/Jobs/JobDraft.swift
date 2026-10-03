import Foundation

nonisolated enum JobField: Sendable {
    case title
    case watchName
    case waitingReason
    case outcome
    case cancellationReason
    case unfinishedTasksReason
}

nonisolated struct JobValidationError: LocalizedError {
    let fields: [JobField: String]

    var errorDescription: String? { "Check the marked fields and try again." }
}

nonisolated struct JobIntakeDraft: Equatable, Sendable {
    var watchName: String
    var brand: String
    var model: String
    var caseReference: String
    var serial: String
    var caliberDesignation: String
    var caliberVariant: String

    init(snapshot: JobIntakeSnapshot) {
        watchName = snapshot.watchName
        brand = snapshot.brand ?? ""
        model = snapshot.model ?? ""
        caseReference = snapshot.caseReference ?? ""
        serial = snapshot.serial ?? ""
        caliberDesignation = snapshot.caliberDesignation ?? ""
        caliberVariant = snapshot.caliberVariant ?? ""
    }

    func snapshot() throws -> JobIntakeSnapshot {
        let name = watchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw JobValidationError(fields: [.watchName: "Enter the watch name at intake."])
        }
        return JobIntakeSnapshot(
            watchName: name, brand: JobDraft.optional(brand), model: JobDraft.optional(model),
            caseReference: JobDraft.optional(caseReference), serial: JobDraft.optional(serial),
            caliberDesignation: JobDraft.optional(caliberDesignation),
            caliberVariant: JobDraft.optional(caliberVariant))
    }
}

nonisolated struct JobDraft: Equatable, Sendable {
    var title = ""
    var reportedProblem = ""
    var agreedScope = ""
    var intakeCondition = ""
    var ownerName = ""
    var ownerEmail = ""
    var ownerPhone = ""
    var intake: JobIntakeDraft?

    init() {}

    init(job: JobRecord) {
        title = job.title
        reportedProblem = job.reportedProblem ?? ""
        agreedScope = job.agreedScope ?? ""
        intakeCondition = job.intakeCondition ?? ""
        ownerName = job.ownerName ?? ""
        ownerEmail = job.ownerEmail ?? ""
        ownerPhone = job.ownerPhone ?? ""
        intake = JobIntakeDraft(snapshot: job.intakeSnapshot)
    }

    func record(
        id: UUID, watchID: UUID, stage: JobStage, snapshot: JobIntakeSnapshot,
        createdAt: Date, updatedAt: Date, existing: JobRecord? = nil
    ) throws -> JobRecord {
        guard let title = Self.optional(title) else {
            throw JobValidationError(fields: [.title: "Enter a job title."])
        }
        return JobRecord(
            id: id, watchID: watchID, title: title, stage: stage,
            reportedProblem: Self.optional(reportedProblem),
            agreedScope: Self.optional(agreedScope),
            intakeCondition: Self.optional(intakeCondition), ownerName: Self.optional(ownerName),
            ownerEmail: Self.optional(ownerEmail), ownerPhone: Self.optional(ownerPhone),
            intakeSnapshot: snapshot, createdAt: createdAt, updatedAt: updatedAt,
            waitingReason: existing?.waitingReason, outcome: existing?.outcome,
            recommendations: existing?.recommendations,
            cancellationReason: existing?.cancellationReason,
            startedAt: existing?.startedAt, completedAt: existing?.completedAt,
            cancelledAt: existing?.cancelledAt,
            unfinishedTasksReason: existing?.unfinishedTasksReason)
    }

    static func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed
    }
}
