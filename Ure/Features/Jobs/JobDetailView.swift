import SwiftUI

struct JobDetailView: View {
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    @Environment(WatchState.self) private var watches
    @Environment(NoteState.self) private var notes

    var body: some View {
        Group {
            if jobs.actionDraft != nil {
                JobActionEditorView()
            } else if jobs.draft != nil {
                JobEditorView()
            } else if let job = jobs.selectedJob, notes.isPresenting(for: .job(job.id)) {
                NoteDetailView(owner: .job(job.id))
            } else if let job = jobs.selectedJob {
                Form {
                    Section("Job") {
                        LabeledContent("Title", value: job.title)
                        LabeledContent("Stage", value: job.stage.rawValue)
                        LabeledContent("Created") {
                            Text(job.createdAt, format: .dateTime)
                        }
                        JobValue(label: "Reported problem", value: job.reportedProblem)
                        JobValue(label: "Agreed scope", value: job.agreedScope)
                        JobValue(label: "Intake condition", value: job.intakeCondition)
                        JobValue(label: "Waiting reason", value: job.waitingReason)
                        if let startedAt = job.startedAt {
                            LabeledContent("Started") { Text(startedAt, format: .dateTime) }
                        }
                    }
                    if let watch = watches.watches.first(where: { $0.id == job.watchID }) {
                        Section("Current watch condition") {
                            LabeledContent("Condition", value: watch.condition.rawValue)
                            JobValue(label: "Condition note", value: watch.conditionNote)
                        }
                    }
                    Section("Outcome") {
                        JobValue(label: "Outcome", value: job.outcome)
                        JobValue(label: "Recommendations", value: job.recommendations)
                        JobValue(label: "Cancellation reason", value: job.cancellationReason)
                        if let completedAt = job.completedAt {
                            LabeledContent("Completed") { Text(completedAt, format: .dateTime) }
                        }
                        if let cancelledAt = job.cancelledAt {
                            LabeledContent("Cancelled") { Text(cancelledAt, format: .dateTime) }
                        }
                        if !job.stage.isOpen {
                            Text("This job is closed. Reopen it to make changes.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("Owner contact") {
                        JobValue(label: "Name", value: job.ownerName)
                        JobValue(label: "Email", value: job.ownerEmail)
                        JobValue(label: "Phone", value: job.ownerPhone)
                    }
                    Section("Identity at intake") {
                        if job.intakeSnapshot.version == 1 {
                            JobIntakeView(snapshot: job.intakeSnapshot)
                        } else {
                            Label(
                                "This job uses an unsupported intake version.",
                                systemImage: "exclamationmark.triangle")
                        }
                    }
                    NoteSectionView(owner: .job(job.id))
                }
                .formStyle(.grouped)
                .textSelection(.enabled)
                .navigationTitle(job.title)
                .toolbar {
                    if job.stage.isOpen {
                        Button("Change Stage", action: changeStage)
                            .accessibilityIdentifier("changeJobStage")
                        Button("Change Condition", action: changeCondition)
                            .accessibilityIdentifier("changeWatchCondition")
                    } else {
                        Button("Reopen Job", action: reopen)
                            .accessibilityIdentifier("reopenJob")
                    }
                    if job.stage.isOpen && job.intakeSnapshot.version == 1 {
                        Button("Edit Intake", action: jobs.edit)
                            .accessibilityIdentifier("editJob")
                    }
                }
            } else {
                ContentUnavailableView(
                    "Job unavailable", systemImage: "wrench.and.screwdriver",
                    description: Text("Return to the watch to choose another job."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back to Watch", systemImage: "chevron.left", action: backToWatch)
                    .accessibilityIdentifier("backToWatch")
                    .disabled(editing.isSaving)
            }
        }
    }

    private func backToWatch() { editing.requestNavigation(jobs.close) }

    private func changeStage() { beginAction(.transition) }
    private func changeCondition() { beginAction(.condition) }
    private func reopen() { beginAction(.reopen) }

    private func beginAction(_ action: JobAction) {
        guard let job = jobs.selectedJob,
            let watch = watches.watches.first(where: { $0.id == job.watchID })
        else { return }
        jobs.beginAction(action, watch: watch)
    }
}

struct JobIntakeView: View {
    let snapshot: JobIntakeSnapshot

    var body: some View {
        LabeledContent("Watch name", value: snapshot.watchName)
        JobValue(label: "Brand", value: snapshot.brand)
        JobValue(label: "Model", value: snapshot.model)
        JobValue(label: "Case reference", value: snapshot.caseReference)
        JobValue(label: "Serial number", value: snapshot.serial)
        JobValue(label: "Caliber designation", value: snapshot.caliberDesignation)
        JobValue(label: "Caliber variant", value: snapshot.caliberVariant)
    }
}

private struct JobValue: View {
    let label: String
    let value: String?

    var body: some View { LabeledContent(label, value: value ?? "Not recorded") }
}
