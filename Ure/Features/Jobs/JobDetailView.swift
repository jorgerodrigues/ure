import SwiftUI

struct JobDetailView: View {
    @Environment(SearchState.self) private var search
    @State private var showsTimeline = false
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    @Environment(WatchState.self) private var watches
    @Environment(NoteState.self) private var notes
    @Environment(DocumentState.self) private var documents
    @Environment(PhotoState.self) private var photos
    @Environment(ReferenceState.self) private var references
    @Environment(JobTaskState.self) private var tasks
    @Environment(PartState.self) private var parts

    var body: some View {
        Group {
            if jobs.actionDraft != nil {
                JobActionEditorView().focusedSceneValue(\.recordBackAction, backAction)
            } else if jobs.draft != nil {
                JobEditorView().focusedSceneValue(\.recordBackAction, backAction)
            } else if let job = jobs.selectedJob, showsTimeline {
                JobTimelineView(jobID: job.id, onClose: closeTimeline)
            } else if let job = jobs.selectedJob, parts.isPresenting(for: job.id) {
                PartDetailView(jobID: job.id)
            } else if let job = jobs.selectedJob, tasks.isPresenting(for: job.id) {
                JobTaskDetailView(jobID: job.id)
            } else if let job = jobs.selectedJob, documents.isPresenting(for: .job(job.id)) {
                DocumentDetailView(owner: .job(job.id))
            } else if let job = jobs.selectedJob, photos.isPresenting(for: .job(job.id)) {
                PhotoDetailView(owner: .job(job.id))
            } else if let job = jobs.selectedJob, references.isPresenting(for: .job(job.id)) {
                ReferenceDetailView(owner: .job(job.id))
            } else if let job = jobs.selectedJob, notes.isPresenting(for: .job(job.id)) {
                NoteDetailView(owner: .job(job.id))
            } else if let job = jobs.selectedJob {
                Form {
                    Section("Job") {
                        LabeledContent("Title", value: job.title)
                        LabeledContent("Stage", value: job.stage.rawValue)
                        JobTaskProgressView(jobID: job.id)
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
                        JobValue(
                            label: "Unfinished tasks explanation", value: job.unfinishedTasksReason)
                        JobValue(
                            label: "Unresolved parts explanation", value: job.unfinishedPartsReason)
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
                    JobTaskSectionView(jobID: job.id)
                    Section("Activity") {
                        Button("Show Activity", action: showTimeline)
                            .disabled(editing.isSaving)
                            .accessibilityIdentifier("showJobActivity")
                    }
                    PartSectionView(jobID: job.id)
                    NoteSectionView(owner: .job(job.id))
                    PhotoSectionView(owner: .job(job.id))
                    ReferenceSectionView(owner: .job(job.id))
                }
                .formStyle(.grouped)
                .textSelection(.enabled)
                .navigationTitle(job.title)
                .focusedSceneValue(\.recordMenuActions, menuActions(for: job))
                .focusedSceneValue(\.recordBackAction, backAction)
                .toolbar {
                    if job.stage.isOpen {
                        Button("Change Stage", action: changeStage)
                            .accessibilityIdentifier("changeJobStage")
                        Button("Change Condition", action: changeCondition)
                            .accessibilityIdentifier("changeWatchCondition")
                    } else {
                        Button("Reopen Job", action: reopen)
                            .disabled(
                                editing.isSaving
                                    || !editing.canWrite(LibraryItemOwner.watch(job.watchID))
                                    || job.archivedAt != nil
                            )
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
        .onChange(of: jobs.selectedID, resetTimeline)
        .onChange(of: parts.selectedID, resetTimeline)
        .onChange(of: search.navigationRevision, resetTimeline)
        .onChange(of: editing.archive.navigationRevision, resetTimeline)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back to Watch", systemImage: "chevron.left", action: backToWatch)
                    .accessibilityIdentifier("backToWatch")
                    .disabled(editing.isSaving)
            }
        }
    }

    private var backAction: (() -> Void)? {
        guard !editing.isSaving else { return nil }
        return backToWatch
    }

    private func backToWatch() { editing.requestNavigation(jobs.close) }
    private func showTimeline() { editing.requestNavigation { showsTimeline = true } }
    private func closeTimeline() { showsTimeline = false }
    private func resetTimeline() { showsTimeline = false }

    private func changeStage() { beginAction(.transition) }
    private func changeCondition() { beginAction(.condition) }
    private func reopen() { beginAction(.reopen) }

    private func beginAction(_ action: JobAction) {
        guard let job = jobs.selectedJob,
            let watch = watches.watches.first(where: { $0.id == job.watchID })
        else { return }
        jobs.beginAction(action, watch: watch)
    }

    private func menuActions(for job: JobRecord) -> RecordMenuActions {
        guard !editing.isSaving else { return RecordMenuActions() }
        var actions = RecordMenuActions()
        if job.stage.isOpen {
            if job.intakeSnapshot.version == 1 { actions.edit = jobs.edit }
            actions.changeStage = changeStage
            actions.changeCondition = changeCondition
        } else if job.archivedAt == nil && editing.canWrite(LibraryItemOwner.watch(job.watchID)) {
            actions.reopen = reopen
        }
        return actions
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
