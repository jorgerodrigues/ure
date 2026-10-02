import SwiftUI

struct JobDetailView: View {
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing

    var body: some View {
        Group {
            if jobs.draft != nil {
                JobEditorView()
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
                }
                .formStyle(.grouped)
                .textSelection(.enabled)
                .navigationTitle(job.title)
                .toolbar {
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
