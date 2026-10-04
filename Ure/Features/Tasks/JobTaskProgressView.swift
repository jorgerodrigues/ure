import SwiftUI

struct JobTaskProgressView: View {
    @Environment(JobTaskState.self) private var tasks
    let jobID: UUID

    var body: some View {
        LabeledContent("Task progress") {
            if tasks.isLoading {
                ProgressView("Loading tasks…")
            } else if tasks.loadError != nil {
                Text("Task progress unavailable").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    if let percentage = progress.percentage {
                        Text(
                            "\(progress.doneCount) of \(progress.countedCount) done · \(percentage)%"
                        )
                        .accessibilityIdentifier("taskProgress")
                    } else {
                        Text("No tasks planned").accessibilityIdentifier("taskProgress")
                    }
                    Text("\(progress.skippedCount) skipped")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("taskSkippedCount")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Task progress: \(progress.accessibilitySummary)")
                .accessibilityIdentifier("taskProgressSummary")
            }
        }
    }

    private var progress: JobTaskProgress { tasks.progress(for: jobID) }
}
