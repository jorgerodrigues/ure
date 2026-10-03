import SwiftUI

struct PartClosureSummaryView: View {
    @Environment(PartState.self) private var parts
    @Environment(JobState.self) private var jobs
    let jobID: UUID

    var body: some View {
        Section("Parts summary") {
            if parts.isLoading {
                ProgressView("Loading parts…")
            } else if let error = parts.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Retry", action: retry)
            } else if parts.records(for: jobID).isEmpty {
                Text("No parts required.").foregroundStyle(.secondary)
            } else {
                ForEach(parts.records(for: jobID)) { part in
                    VStack(alignment: .leading) {
                        LabeledContent(part.record.description, value: part.record.status.rawValue)
                        if part.record.status.isUnresolved {
                            if let supplier = part.record.supplierSnapshot?.supplierName {
                                Text("Ordered from \(supplier)").font(.caption).foregroundStyle(
                                    .secondary)
                            }
                            if let reference = part.record.orderReference {
                                Text("Order reference: \(reference)").font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("These parts will keep their current status.").foregroundStyle(.secondary)
            }
            if hasUnresolvedParts || jobs.fieldErrors[.unfinishedPartsReason] != nil {
                TextField("Unresolved parts explanation", text: explanation, axis: .vertical)
                    .accessibilityIdentifier("jobUnfinishedPartsReason")
                if let error = jobs.fieldErrors[.unfinishedPartsReason] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }
    private var hasUnresolvedParts: Bool {
        parts.records(for: jobID).contains { $0.record.status.isUnresolved }
    }
    private var explanation: Binding<String> {
        Binding(get: currentExplanation, set: setExplanation)
    }
    private func currentExplanation() -> String {
        jobs.actionDraft?.transition.unfinishedPartsReason ?? ""
    }
    private func setExplanation(_ value: String) {
        jobs.actionDraft?.transition.unfinishedPartsReason = value
    }
    private func retry() { Task { await parts.observe() } }
}
