import SwiftUI

struct JobTaskDetailView: View {
    @Environment(JobTaskState.self) private var tasks
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let jobID: UUID

    var body: some View {
        Group {
            if tasks.draft != nil {
                JobTaskEditorView(jobID: jobID)
            } else if let error = tasks.loadError {
                ContentUnavailableView {
                    Label("Tasks unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry", action: retry)
                }
            } else if let task = tasks.selectedTask {
                Form {
                    Section("Job task") {
                        LabeledContent("Title", value: task.title)
                        LabeledContent("Status", value: task.status.rawValue)
                        if let group = task.groupLabel { LabeledContent("Group", value: group) }
                        if let reason = task.waitingReason {
                            LabeledContent("Waiting reason", value: reason)
                        }
                        if let reason = task.skippedReason {
                            LabeledContent("Skipped reason", value: reason)
                        }
                        LabeledContent("Created") { Text(task.createdAt, format: .dateTime) }
                        LabeledContent("Updated") { Text(task.updatedAt, format: .dateTime) }
                    }
                    if !tasks.linkedParts(for: task.id).isEmpty {
                        Section("Required parts") {
                            if let availability = tasks.availability(for: task.id) {
                                Text(availability.rawValue)
                                    .accessibilityIdentifier("taskAvailability")
                            }
                            ForEach(tasks.linkedParts(for: task.id)) { part in
                                LabeledContent(part.description, value: part.status.rawValue)
                            }
                        }
                    }
                    Section("Task order") {
                        Button("Move up", action: moveUp)
                            .disabled(!canMove(.up))
                            .accessibilityIdentifier("moveTaskUp")
                        Button("Move down", action: moveDown)
                            .disabled(!canMove(.down))
                            .accessibilityIdentifier("moveTaskDown")
                        if let error = tasks.reorderError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .accessibilityIdentifier("taskReorderError")
                        }
                    }
                    if let detail = task.detail {
                        Section("Detail") {
                            Text(detail).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !tasks.canWrite(jobID, jobs: jobs) {
                        Section { Text("Reopen a closed job to change its tasks.") }
                    }
                }
                .formStyle(.grouped)
                .textSelection(.enabled)
                .navigationTitle(task.title)
                .toolbar {
                    Button("Edit Task", action: edit)
                        .disabled(editing.isSaving || !tasks.canWrite(jobID, jobs: jobs))
                        .accessibilityIdentifier("editTask")
                }
            } else {
                ContentUnavailableView("Task unavailable", systemImage: "checklist")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back to Job", systemImage: "chevron.left", action: back)
                    .disabled(editing.isSaving)
                    .accessibilityIdentifier("backFromTask")
            }
        }
    }

    private func edit() { tasks.edit(jobs: jobs) }
    private func back() { editing.requestNavigation(tasks.close) }
    private func retry() { Task { await tasks.observe() } }

    private func canMove(_ destination: JobTaskMove) -> Bool {
        guard let task = tasks.selectedTask, !editing.isSaving, !editing.hasUnsavedChanges else {
            return false
        }
        return tasks.canMove(task.id, for: jobID, to: destination, jobs: jobs)
    }

    private func moveUp() { move(.up) }
    private func moveDown() { move(.down) }

    private func move(_ destination: JobTaskMove) {
        guard canMove(destination), let task = tasks.selectedTask else { return }
        tasks.moveCommand(task.id, for: jobID, to: destination, jobs: jobs)
    }
}
