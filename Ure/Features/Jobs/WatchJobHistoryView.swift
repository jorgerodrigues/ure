import SwiftUI

struct WatchJobHistoryView: View {
    @State private var searchText = ""
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let watch: WatchRecord

    var body: some View {
        Section("Repair history") {
            if jobs.isLoading {
                ProgressView("Loading jobs…")
            } else if let error = jobs.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Retry", action: retry)
            } else {
                Button(actionTitle, action: startJob)
                    .accessibilityIdentifier("startWatchJob")
                    .disabled(editing.isSaving || watch.archivedAt != nil)
                TextField("Filter job titles", text: $searchText)
                    .accessibilityIdentifier("jobsLocalSearch")
                if filteredJobs.isEmpty {
                    Text(searchText.isEmpty ? "No repair jobs yet." : "No matching jobs.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredJobs) { job in
                        WatchJobLink(job: job)
                    }
                }
            }
        }
    }

    private var filteredJobs: [JobRecord] {
        jobs.history(for: watch.id).filter { SearchKey.matches([$0.title], query: searchText) }
    }

    private var actionTitle: String {
        if jobs.openJob(for: watch.id) != nil { return "Open Job" }
        return "Start Job"
    }

    private func startJob() {
        editing.requestNavigation { jobs.start(for: watch.id) }
    }

    private func retry() { Task { await jobs.observe() } }
}

private struct WatchJobLink: View {
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let job: JobRecord

    var body: some View {
        Button(action: openJob) {
            HStack {
                Text(job.title)
                Spacer()
                Text(job.stage.rawValue)
                    .foregroundStyle(.secondary)
                Text(job.createdAt, format: .dateTime.year().month().day())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("watchJob-\(job.id.uuidString)")
        .disabled(editing.isSaving)
    }

    private func openJob() { editing.requestNavigation { jobs.open(job) } }
}
