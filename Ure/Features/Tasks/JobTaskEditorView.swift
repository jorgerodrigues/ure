import SwiftUI

struct JobTaskEditorView: View {
    @Environment(JobTaskState.self) private var tasks
    @Environment(JobState.self) private var jobs
    @FocusState private var titleFocused: Bool
    let jobID: UUID

    var body: some View {
        Form {
            Section("Job task") {
                TextField("Title", text: field(\.title))
                    .focused($titleFocused)
                    .accessibilityIdentifier("taskTitle")
                JobTaskFieldError(message: tasks.fieldErrors[.title])
                TextField("Group label (optional)", text: field(\.groupLabel))
                    .accessibilityIdentifier("taskGroupLabel")
                Picker("Status", selection: status) {
                    ForEach(JobTaskStatus.allCases) { status in Text(status.rawValue).tag(status) }
                }
                .accessibilityIdentifier("taskStatus")
                if tasks.draft?.status == .waiting {
                    TextField("Waiting reason", text: field(\.waitingReason), axis: .vertical)
                        .accessibilityIdentifier("taskWaitingReason")
                    JobTaskFieldError(message: tasks.fieldErrors[.waitingReason])
                    Text(
                        "A Needed or Ordered part can explain the wait. Parts becoming available leave the task Waiting."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                } else if tasks.draft?.status == .skipped {
                    TextField("Skipped reason", text: field(\.skippedReason), axis: .vertical)
                        .accessibilityIdentifier("taskSkippedReason")
                    JobTaskFieldError(message: tasks.fieldErrors[.skippedReason])
                }
            }
            Section("Required parts") {
                if tasks.availableParts(for: jobID).isEmpty {
                    Text("No parts recorded for this job.").foregroundStyle(.secondary)
                } else {
                    ForEach(tasks.availableParts(for: jobID)) { part in
                        TaskPartSelectionRow(part: part)
                    }
                }
            }
            Section("Detail (optional)") {
                TextEditor(text: field(\.detail))
                    .frame(minHeight: 160)
                    .accessibilityLabel("Task detail")
                    .accessibilityIdentifier("taskDetail")
            }
            if !tasks.canWrite(jobID, jobs: jobs) {
                Section {
                    Text("Task editing is unavailable. Reopen a closed job to change its tasks.")
                }
            }
            if let error = tasks.saveError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("taskSaveError")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(tasks.isSaving || !tasks.canWrite(jobID, jobs: jobs))
        .navigationTitle(tasks.selectedID == nil ? "New Task" : "Edit Task")
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                if tasks.isSaving { ProgressView().controlSize(.small) }
                Button("Cancel", action: tasks.cancel).disabled(tasks.isSaving)
                    .accessibilityIdentifier("cancelTask")
                Button("Save", action: tasks.saveCommand).disabled(!tasks.canSave(jobs: jobs))
                    .accessibilityIdentifier("saveTask")
            }
        }
        .onAppear(perform: focusTitle)
    }

    private var status: Binding<JobTaskStatus> { Binding(get: currentStatus, set: selectStatus) }
    private func currentStatus() -> JobTaskStatus { tasks.draft?.status ?? .toDo }
    private func selectStatus(_ status: JobTaskStatus) { tasks.draft?.status = status }
    private func focusTitle() { titleFocused = true }

    private func field(_ keyPath: WritableKeyPath<JobTaskDraft, String>) -> Binding<String> {
        Binding(
            get: { tasks.draft?[keyPath: keyPath] ?? "" },
            set: { tasks.draft?[keyPath: keyPath] = $0 })
    }
}

private struct TaskPartSelectionRow: View {
    @Environment(JobTaskState.self) private var tasks
    let part: PartRecord

    var body: some View {
        Toggle(isOn: Binding(get: isSelected, set: select)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(part.description)
                Text("Quantity \(part.quantity) · \(part.status.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
                if let reference = part.manufacturerReference {
                    Text(reference).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("taskPart-\(part.id.uuidString)")
    }

    private func isSelected() -> Bool { tasks.draft?.partIDs.contains(part.id) == true }
    private func select(_ value: Bool) { tasks.selectPart(part.id, selected: value) }
}

private struct JobTaskFieldError: View {
    let message: String?
    var body: some View {
        if let message {
            Text(message).font(.caption).foregroundStyle(.red)
                .accessibilityLabel("Field error: \(message)")
        }
    }
}
