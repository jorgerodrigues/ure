import SwiftUI

struct JobActionEditorView: View {
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing

    var body: some View {
        Form {
            if let draft = jobs.actionDraft {
                if draft.action == .condition {
                    Section("Physical watch condition") {
                        Picker(
                            "Condition", selection: field(\.condition.condition, default: .unknown)
                        ) {
                            ForEach(WatchCondition.allCases, id: \.self) { condition in
                                Text(condition.rawValue).tag(condition)
                            }
                        }
                        .accessibilityIdentifier("watchCondition")
                        TextField(
                            "Condition note (optional)", text: field(\.condition.note, default: ""),
                            axis: .vertical
                        )
                        .accessibilityIdentifier("watchConditionNote")
                    }
                } else {
                    Section("Job stage") {
                        Picker("Stage", selection: field(\.transition.stage, default: .planned)) {
                            ForEach(stages, id: \.self) { stage in
                                Text(stage.rawValue).tag(stage)
                            }
                        }
                        .accessibilityIdentifier("jobStage")
                        Text("Ready means ready for final review.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if draft.transition.stage == .waiting {
                            TextField(
                                "Waiting reason",
                                text: field(\.transition.waitingReason, default: ""),
                                axis: .vertical
                            )
                            .accessibilityIdentifier("jobWaitingReason")
                            JobActionFieldError(message: jobs.fieldErrors[.waitingReason])
                        } else if draft.transition.stage == .completed {
                            TextField(
                                "Outcome", text: field(\.transition.outcome, default: ""),
                                axis: .vertical
                            )
                            .accessibilityIdentifier("jobOutcome")
                            JobActionFieldError(message: jobs.fieldErrors[.outcome])
                            TextField(
                                "Recommendations (optional)",
                                text: field(\.transition.recommendations, default: ""),
                                axis: .vertical
                            )
                            .accessibilityIdentifier("jobRecommendations")
                            Text("Completing this job locks operational edits.")
                                .foregroundStyle(.secondary)
                        } else if draft.transition.stage == .cancelled {
                            TextField(
                                "Cancellation reason",
                                text: field(\.transition.cancellationReason, default: ""),
                                axis: .vertical
                            )
                            .accessibilityIdentifier("jobCancellationReason")
                            JobActionFieldError(message: jobs.fieldErrors[.cancellationReason])
                            Text("Cancelling this job locks operational edits.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !draft.transition.stage.isOpen, let jobID = jobs.selectedID {
                        JobTaskClosureSummaryView(jobID: jobID)
                        PartClosureSummaryView(jobID: jobID)
                    }
                }
            }
            if let error = jobs.saveError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("jobActionSaveError")
                    if jobs.conflictingJobID != nil {
                        Button("Open Existing Job", action: jobs.openConflictingJob)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(jobs.isSaving)
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                if jobs.isSaving { ProgressView().controlSize(.small) }
                Button("Cancel", action: jobs.cancel)
                    .accessibilityIdentifier("cancelJobAction")
                    .disabled(jobs.isSaving)
                Button("Save", action: editing.saveJobCommand)
                    .accessibilityIdentifier("saveJobAction")
                    .disabled(!editing.canSaveJob)
            }
        }
    }

    private var stages: [JobStage] {
        if jobs.actionDraft?.action == .reopen { return JobStage.allCases.filter(\.isOpen) }
        return JobStage.allCases
    }

    private var title: String {
        switch jobs.actionDraft?.action {
        case .transition: "Change Job Stage"
        case .reopen: "Reopen Job"
        case .condition: "Change Watch Condition"
        case nil: "Job"
        }
    }

    private func field<Value>(
        _ keyPath: WritableKeyPath<JobActionDraft, Value>, default value: Value
    ) -> Binding<Value> {
        Binding(
            get: { jobs.actionDraft?[keyPath: keyPath] ?? value },
            set: { jobs.actionDraft?[keyPath: keyPath] = $0 })
    }
}

private struct JobTaskClosureSummaryView: View {
    @Environment(JobTaskState.self) private var tasks
    @Environment(JobState.self) private var jobs
    let jobID: UUID

    var body: some View {
        Section("Task summary") {
            if tasks.isLoading {
                ProgressView("Loading tasks…")
            } else if let error = tasks.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Retry", action: retry)
            } else if records.isEmpty {
                Text("No tasks planned.").foregroundStyle(.secondary)
            } else {
                ForEach(JobTaskStatus.allCases) { status in
                    LabeledContent(
                        status.rawValue, value: String(records.filter { $0.status == status }.count)
                    )
                }
                if !unfinished.isEmpty {
                    Text("These tasks will keep their current status:").foregroundStyle(.secondary)
                    ForEach(unfinished) { task in
                        LabeledContent(task.title, value: task.status.rawValue)
                    }
                }
            }
            if !unfinished.isEmpty || jobs.fieldErrors[.unfinishedTasksReason] != nil {
                TextField("Unfinished tasks explanation", text: explanation, axis: .vertical)
                    .accessibilityIdentifier("jobUnfinishedTasksReason")
                JobActionFieldError(message: jobs.fieldErrors[.unfinishedTasksReason])
            }
        }
    }

    private var records: [JobTaskRecord] { tasks.records(for: jobID) }
    private var unfinished: [JobTaskRecord] { records.filter { $0.status.isUnfinished } }
    private var explanation: Binding<String> {
        Binding(get: currentExplanation, set: setExplanation)
    }
    private func currentExplanation() -> String {
        jobs.actionDraft?.transition.unfinishedTasksReason ?? ""
    }
    private func setExplanation(_ value: String) {
        jobs.actionDraft?.transition.unfinishedTasksReason = value
    }
    private func retry() { Task { await tasks.observe() } }
}

private struct JobActionFieldError: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message).font(.caption).foregroundStyle(.red)
                .accessibilityLabel("Field error: \(message)")
        }
    }
}
