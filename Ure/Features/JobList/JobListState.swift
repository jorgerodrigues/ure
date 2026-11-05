import Foundation
import GRDB
import Observation

// The three groups of the Jobs list, in the order they show.
nonisolated enum JobListGroup: CaseIterable, Sendable {
    case inProgress
    case waiting
    case doneRecently

    var title: String {
        switch self {
        case .inProgress: "In progress"
        case .waiting: "Waiting"
        case .doneRecently: "Done recently"
        }
    }

    init(_ stage: JobStage) {
        switch stage {
        case .inProgress: self = .inProgress
        case .waiting: self = .waiting
        case .done: self = .doneRecently
        }
    }
}

// The Jobs list: every open job once, grouped by In progress and Waiting, and the jobs done in
// the last 30 days. Older Done jobs stay on their watch's page and in search.
@Observable
final class JobListState {
    // A job done on any day from 30 days ago to today is done recently.
    static let recentDays = 30

    private let coordinator: LibraryCoordinator
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    private(set) var rows: [JobListRow] = []
    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var navigationError: String?
    private(set) var observationRevision = 0
    // The first moment that is still recent. It moves on when the day changes.
    private(set) var cutoff: Date
    var searchText = ""

    init(
        coordinator: LibraryCoordinator, now: @escaping () -> Date = { .now },
        calendar: Calendar = .current
    ) {
        self.coordinator = coordinator
        self.now = now
        self.calendar = calendar
        cutoff = Self.recentCutoff(now: now(), calendar: calendar)
    }

    // The start of the day 30 days before today. A job done at or after it is done recently.
    static func recentCutoff(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -recentDays, to: today) ?? today
    }

    // The day changed, at midnight or while the Mac slept, so a job done 31 days ago now
    // leaves Done recently and the sidebar's count.
    func refreshDay() {
        let next = Self.recentCutoff(now: now(), calendar: calendar)
        if next != cutoff { cutoff = next }
    }

    // The rows the list shows, before the search. The sidebar counts them.
    var listedRows: [JobListRow] {
        rows.filter { row in
            guard row.job.stage == .done else { return true }
            guard let doneAt = row.job.doneAt else { return false }
            return doneAt >= cutoff
        }
    }

    var filteredRows: [JobListRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return listedRows }
        return listedRows.filter { row in
            SearchKey.matches(
                [
                    row.watch?.name, row.watch?.brand, row.watch?.model, row.watch?.owner,
                    row.job.title, row.job.waitingFor,
                ], query: query)
        }
    }

    // Open jobs come newest change first, and done jobs latest done first.
    func rows(in group: JobListGroup) -> [JobListRow] {
        filteredRows.filter { JobListGroup($0.job.stage) == group }
            .sorted { lhs, rhs in
                let left = group == .doneRecently ? lhs.job.doneAt ?? lhs.updatedAt : lhs.updatedAt
                let right = group == .doneRecently ? rhs.job.doneAt ?? rhs.updatedAt : rhs.updatedAt
                if left != right { return left > right }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    var openCount: Int { rows.filter { $0.job.stage.isOpen }.count }
    var waitingCount: Int { rows.filter { $0.job.stage == .waiting }.count }

    // The toolbar's subtitle, such as "4 open · 1 waiting".
    var subtitle: String {
        guard openCount > 0 else { return "No open jobs" }
        guard waitingCount > 0 else { return "\(openCount) open" }
        return "\(openCount) open · \(waitingCount) waiting"
    }

    func contains(_ id: UUID?) -> Bool { listedRows.contains { $0.id == id } }

    func selectionMessage(for job: JobRecord?) -> String? {
        guard !isLoading, loadError == nil, let job else { return nil }
        if !contains(job.id) {
            return "This job was done more than 30 days ago. It stays on its watch’s page."
        }
        if !filteredRows.contains(where: { $0.id == job.id }) {
            return "The selected job is outside the current search. Its page stays open."
        }
        return nil
    }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            refreshDay()
            let values = try await coordinator.jobListValues(doneSince: cutoff)
            for try await rows in values {
                try Task.checkCancellation()
                self.rows = rows
                isLoading = false
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    func retry() { observationRevision += 1 }

    func clearSearch() { searchText = "" }

    // Opens a job from the list, with its watch selected when it has one.
    func open(_ id: UUID?, editing: WorkshopEditing) {
        guard let id, !isLoading, loadError == nil else { return }
        editing.requestNavigation {
            self.navigationError = nil
            guard self.rows.contains(where: { $0.id == id }),
                !editing.jobs.isLoading, editing.jobs.loadError == nil,
                !editing.watches.isLoading, editing.watches.loadError == nil,
                let job = editing.jobs.jobs.first(where: { $0.id == id })
            else {
                self.navigationError = "The job is unavailable. Retry loading the jobs."
                return
            }
            editing.closeChildren()
            editing.watches.select(job.watchID)
            editing.jobs.open(job)
        }
    }
}

// How the Jobs list words a row.
enum JobListWording {
    // The watch's name, or the job's title while it has no watch.
    static func title(of row: JobListRow) -> String {
        row.watch?.name ?? row.job.title
    }

    // The line under the name, such as "Full service · 6 of 10 · 1 to buy",
    // "Waiting for a mainspring", "New crystal · Done 2 Oct" or "No watch yet".
    static func detail(of row: JobListRow, now: Date = .now) -> String {
        guard row.watch != nil else { return "No watch yet" }
        switch row.job.stage {
        case .waiting:
            guard let waitingFor = row.job.waitingFor else { return "Waiting" }
            return "Waiting for \(waitingFor)"
        case .done:
            guard let doneAt = row.job.doneAt else { return row.job.title }
            return "\(row.job.title) · Done \(ArchivedDate.short(doneAt, now: now))"
        case .inProgress:
            var parts = [row.job.title]
            if row.progress.countedCount > 0 {
                parts.append("\(row.progress.doneCount) of \(row.progress.countedCount)")
            }
            if row.partsToBuy > 0 { parts.append("\(row.partsToBuy) to buy") }
            return parts.joined(separator: " · ")
        }
    }
}
