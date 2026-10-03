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
                if let error = tasks.reorderError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("taskReorderError")
                }
                if tasks.records(for: jobID).isEmpty {
                    Text("No tasks planned.").foregroundStyle(.secondary)
                } else {
                    ForEach(tasks.records(for: jobID)) { task in JobTaskRow(task: task) }
                    if tasks.canReorder(jobID, jobs: jobs) {
                        Text("Drag tasks into order. Drop here to move a task to the end.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .dropDestination(
                                for: String.self, isEnabled: !editing.isSaving, action: dropAtEnd)
                    }
                }
            }
        }
    }

    private func create() { editing.requestNavigation { tasks.create(for: jobID, jobs: jobs) } }
    private func retry() { Task { await tasks.observe() } }

    private func dropAtEnd(_ items: [String], _ session: DropSession) {
        guard !editing.isSaving, !editing.hasUnsavedChanges, items.count == 1,
            let item = items.first, let id = UUID(uuidString: item)
        else { return }
        tasks.moveCommand(id, for: jobID, to: .end, jobs: jobs)
    }
}

private struct JobTaskRow: View {
    @Environment(JobTaskState.self) private var tasks
    @Environment(JobState.self) private var jobs
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
                    if let availability = tasks.availability(for: task.id) {
                        Text(availability.rawValue).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("taskAvailability-\(task.id.uuidString)")
                    }
                }
                Spacer()
                Text(task.status.rawValue).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }
        }
        .disabled(editing.isSaving)
        .accessibilityIdentifier("task-\(task.id.uuidString)")
        .contextMenu {
            Button("Move up", action: moveUp).disabled(!canMove(.up))
            Button("Move down", action: moveDown).disabled(!canMove(.down))
        }
        .draggable(String.self, id: \.self, dragPayload)
        .dropDestination(for: String.self, isEnabled: canReorder, action: dropBefore)
        .accessibilityAction(named: "Move up", moveUp)
        .accessibilityAction(named: "Move down", moveDown)
    }

    private func open() { editing.requestNavigation { tasks.open(task, for: task.jobID) } }

    private var canReorder: Bool {
        !editing.isSaving && !editing.hasUnsavedChanges && tasks.canReorder(task.jobID, jobs: jobs)
    }

    private func canMove(_ destination: JobTaskMove) -> Bool {
        canReorder && tasks.canMove(task.id, for: task.jobID, to: destination, jobs: jobs)
    }

    private func dragPayload() -> String? {
        guard canReorder else { return nil }
        return task.id.uuidString
    }

    private func dropBefore(_ items: [String], _ session: DropSession) {
        guard canReorder, items.count == 1, let item = items.first, let id = UUID(uuidString: item)
        else { return }
        tasks.moveCommand(id, for: task.jobID, to: .before(task.id), jobs: jobs)
    }

    private func moveUp() { move(.up) }
    private func moveDown() { move(.down) }

    private func move(_ destination: JobTaskMove) {
        guard canMove(destination) else { return }
        tasks.moveCommand(task.id, for: task.jobID, to: destination, jobs: jobs)
    }
}
