import SwiftUI

struct WatchJobHistoryView: View {
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
                    .disabled(editing.isSaving)
                if jobs.history(for: watch.id).isEmpty {
                    Text("No repair jobs yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(jobs.history(for: watch.id)) { job in
                        WatchJobLink(job: job)
                    }
                }
            }
        }
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
