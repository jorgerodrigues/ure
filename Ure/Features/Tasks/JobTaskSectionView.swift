import SwiftUI

struct JobTaskSectionView: View {
    @Environment(JobTaskState.self) private var tasks
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let jobID: UUID

    var body: some View {
        Section("Tasks") {
            if tasks.isLoading {
                ProgressView("Loading tasks…")
            } else if let error = tasks.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Retry", action: retry)
            } else {
                Button("Add Task", systemImage: "plus", action: create)
                    .disabled(editing.isSaving || !tasks.canWrite(jobID, jobs: jobs))
                    .accessibilityIdentifier("addTask")
                if tasks.records(for: jobID).isEmpty {
                    Text("No tasks planned.").foregroundStyle(.secondary)
                } else {
                    ForEach(tasks.records(for: jobID)) { task in JobTaskRow(task: task) }
                }
            }
        }
    }

    private func create() { editing.requestNavigation { tasks.create(for: jobID, jobs: jobs) } }
    private func retry() { Task { await tasks.observe() } }
}

private struct JobTaskRow: View {
    @Environment(JobTaskState.self) private var tasks
    @Environment(WorkshopEditing.self) private var editing
    let task: JobTaskRecord

    var body: some View {
        Button(action: open) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                    if let group = task.groupLabel {
                        Text(group).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(task.status.rawValue).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }
        }
        .disabled(editing.isSaving)
        .accessibilityIdentifier("task-\(task.id.uuidString)")
    }

    private func open() { editing.requestNavigation { tasks.open(task, for: task.jobID) } }
}
