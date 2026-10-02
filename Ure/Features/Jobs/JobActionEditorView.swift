import SwiftUI

struct JobActionEditorView: View {
    @Environment(JobState.self) private var jobs

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
                Button("Save", action: jobs.saveCommand)
                    .accessibilityIdentifier("saveJobAction")
                    .disabled(!jobs.canSave)
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

private struct JobActionFieldError: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message).font(.caption).foregroundStyle(.red)
                .accessibilityLabel("Field error: \(message)")
        }
    }
}
