import SwiftUI

struct JobEditorView: View {
    @Environment(JobState.self) private var jobs
    @FocusState private var focusedField: JobField?

    var body: some View {
        Form {
            Section("Intake") {
                TextField("Job title", text: field(\.title))
                    .focused($focusedField, equals: .title)
                    .accessibilityIdentifier("jobTitle")
                JobFieldError(message: jobs.fieldErrors[.title])
                TextField("Reported problem", text: field(\.reportedProblem), axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("jobReportedProblem")
                TextField("Agreed scope", text: field(\.agreedScope), axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("jobAgreedScope")
                TextField("Intake condition", text: field(\.intakeCondition), axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("jobIntakeCondition")
            }
            Section("Owner contact (optional)") {
                TextField("Name", text: field(\.ownerName))
                    .accessibilityIdentifier("jobOwnerName")
                TextField("Email", text: field(\.ownerEmail))
                    .accessibilityIdentifier("jobOwnerEmail")
                TextField("Phone", text: field(\.ownerPhone))
                    .accessibilityIdentifier("jobOwnerPhone")
            }
            Section("Identity at intake") {
                if jobs.draft?.intake != nil {
                    TextField("Watch name", text: intakeField(\.watchName))
                        .accessibilityIdentifier("jobIntakeWatchName")
                    JobFieldError(message: jobs.fieldErrors[.watchName])
                    TextField("Brand", text: intakeField(\.brand))
                    TextField("Model", text: intakeField(\.model))
                    TextField("Case reference", text: intakeField(\.caseReference))
                    TextField("Serial number", text: intakeField(\.serial))
                    TextField("Caliber designation", text: intakeField(\.caliberDesignation))
                    TextField("Caliber variant", text: intakeField(\.caliberVariant))
                    Text("Corrections apply to this job only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        "The saved watch and caliber identity will be copied when you save this job."
                    )
                    .foregroundStyle(.secondary)
                }
            }
            if let error = jobs.saveError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("jobSaveError")
                    if jobs.conflictingJobID != nil {
                        Button("Open Existing Job", action: jobs.openConflictingJob)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(jobs.isSaving)
        .navigationTitle(editorTitle)
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                if jobs.isSaving { ProgressView().controlSize(.small) }
                Button("Cancel", action: jobs.cancel)
                    .accessibilityIdentifier("cancelJob")
                    .disabled(jobs.isSaving)
                Button("Save", action: jobs.saveCommand)
                    .accessibilityIdentifier("saveJob")
                    .disabled(!jobs.canSave)
            }
        }
        .onAppear(perform: focusTitle)
    }

    private var editorTitle: String {
        if jobs.selectedID == nil { return "New Job" }
        return "Edit Intake"
    }

    private func focusTitle() { focusedField = .title }

    private func field(_ keyPath: WritableKeyPath<JobDraft, String>) -> Binding<String> {
        Binding(
            get: { jobs.draft?[keyPath: keyPath] ?? "" },
            set: { jobs.draft?[keyPath: keyPath] = $0 })
    }

    private func intakeField(_ keyPath: WritableKeyPath<JobIntakeDraft, String>) -> Binding<String>
    {
        Binding(
            get: { jobs.draft?.intake?[keyPath: keyPath] ?? "" },
            set: { jobs.draft?.intake?[keyPath: keyPath] = $0 })
    }
}

private struct JobFieldError: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel("Field error: \(message)")
        }
    }
}
