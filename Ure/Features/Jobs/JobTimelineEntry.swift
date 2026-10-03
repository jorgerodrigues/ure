import Foundation

nonisolated enum JobTimelineSource: Equatable, Sendable {
    case job(UUID)
    case watch(UUID)
    case task(UUID)
    case part(UUID)
    case note(UUID)

    var label: String {
        switch self {
        case .job: "Open Job"
        case .watch: "Open Watch"
        case .task: "Open Task"
        case .part: "Open Part"
        case .note: "Open Note"
        }
    }
}

nonisolated struct JobTimelineField: Equatable, Identifiable, Sendable {
    let label: String
    let text: String?
    let date: Date?
    var id: String { label }

    init(_ label: String, _ text: String?) {
        self.label = label
        self.text = text
        date = nil
    }

    init(_ label: String, date: Date?) {
        self.label = label
        text = nil
        self.date = date
    }
}

nonisolated struct JobTimelineEntry: Equatable, Identifiable, Sendable {
    enum ID: Equatable, Hashable, Sendable {
        case event(UUID)
        case note(UUID)
    }

    let id: ID
    let occurredAt: Date
    let ordering: Int64?
    let title: String
    let subject: String?
    let summary: String
    let body: String?
    let prior: [JobTimelineField]
    let next: [JobTimelineField]
    let source: JobTimelineSource?
    let unavailableSource: String?

    static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
        switch (lhs.id, rhs.id) {
        case (.event(let left), .event(let right)):
            if lhs.ordering != rhs.ordering { return (lhs.ordering ?? 0) > (rhs.ordering ?? 0) }
            return left.uuidString < right.uuidString
        case (.event, .note): return true
        case (.note, .event): return false
        case (.note(let left), .note(let right)): return left.uuidString < right.uuidString
        }
    }

    init(note: NoteRecord) {
        id = .note(note.id)
        occurredAt = note.occurredAt
        ordering = nil
        title = note.title
        subject = nil
        summary = note.kind.rawValue
        body = note.body
        prior = []
        next = []
        source = .note(note.id)
        unavailableSource = nil
    }

    init(event: ActivityEvent, watchID: UUID, taskIDs: Set<UUID>, partIDs: Set<UUID>) throws {
        id = .event(event.id)
        occurredAt = event.occurredAt
        ordering = event.ordering
        title = event.kind.rawValue
        body = nil
        switch (event.kind, event.priorValue, event.nextValue) {
        case (.jobStageChanged, .job(let previous), .job(let current)):
            subject = nil
            summary = Self.transition(previous.stage.rawValue, current.stage.rawValue)
            prior = Self.fields(previous)
            next = Self.fields(current)
            source = .job(event.jobID)
            unavailableSource = nil
        case (.watchConditionChanged, .condition(let previous), .condition(let current)):
            subject = nil
            summary = Self.transition(previous.condition.rawValue, current.condition.rawValue)
            prior = Self.fields(previous)
            next = Self.fields(current)
            source = .watch(watchID)
            unavailableSource = nil
        case (.taskStatusChanged, .task(let previous), .task(let current)):
            guard previous.taskID == current.taskID else { throw JobTimelineError.invalidEvent }
            subject = current.title
            summary = Self.transition(previous.status?.rawValue, current.status?.rawValue)
            prior = Self.fields(previous)
            next = Self.fields(current)
            source = taskIDs.contains(current.taskID) ? .task(current.taskID) : nil
            unavailableSource = source == nil ? "This task is no longer available." : nil
        case (.partStatusChanged, .part(let previous), .part(let current)):
            guard previous.partID == current.partID else { throw JobTimelineError.invalidEvent }
            subject = current.description
            summary = Self.transition(previous.status?.rawValue, current.status?.rawValue)
            prior = Self.fields(previous)
            next = Self.fields(current)
            source = partIDs.contains(current.partID) ? .part(current.partID) : nil
            unavailableSource = source == nil ? "This part is no longer available." : nil
        default: throw JobTimelineError.invalidEvent
        }
    }

    private static func transition(_ previous: String?, _ current: String?) -> String {
        guard let previous else { return "Created as \(current ?? "Not recorded")" }
        if previous == current { return "Status: \(previous)" }
        return "\(previous) to \(current ?? "Not recorded")"
    }

    private static func fields(_ value: JobStageValue) -> [JobTimelineField] {
        [
            .init("Stage", value.stage.rawValue),
            .init("Waiting reason", value.waitingReason),
            .init("Outcome", value.outcome),
            .init("Recommendations", value.recommendations),
            .init("Cancellation reason", value.cancellationReason),
            .init("Unfinished tasks explanation", value.unfinishedTasksReason),
            .init("Unresolved parts explanation", value.unfinishedPartsReason),
            .init("Started", date: value.startedAt),
            .init("Completed", date: value.completedAt),
            .init("Cancelled", date: value.cancelledAt),
        ]
    }

    private static func fields(_ value: WatchConditionValue) -> [JobTimelineField] {
        [.init("Condition", value.condition.rawValue), .init("Condition note", value.note)]
    }

    private static func fields(_ value: JobTaskValue) -> [JobTimelineField] {
        [
            .init("Task", value.title), .init("Status", value.status?.rawValue),
            .init("Waiting reason", value.waitingReason),
            .init("Skipped reason", value.skippedReason),
        ]
    }

    private static func fields(_ value: PartProcurementValue) -> [JobTimelineField] {
        [
            .init("Part", value.description), .init("Quantity", String(value.quantity)),
            .init("Status", value.status?.rawValue), .init("Reason", value.reason),
            .init("Ordered", date: value.orderedAt), .init("Arrived", date: value.arrivedAt),
            .init("Installed", date: value.installedAt),
            .init("Cancelled", date: value.cancelledAt),
            .init("Order reference", value.orderReference),
            .init("Supplier", value.supplierSnapshot?.supplierName),
            .init("Listing", value.supplierSnapshot?.title),
            .init("Supplier stock code", value.supplierSnapshot?.supplierStockCode),
            .init("Supplier URL", value.supplierSnapshot?.url),
            .init("Price", value.supplierSnapshot?.price),
            .init("Currency", value.supplierSnapshot?.currency),
            .init("Supplier notes", value.supplierSnapshot?.notes),
        ]
    }
}
