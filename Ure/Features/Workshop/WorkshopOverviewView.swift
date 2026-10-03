import SwiftUI

struct WorkshopOverviewView: View {
    @Environment(WorkshopOverviewState.self) private var workshop
    @Environment(WorkshopEditing.self) private var editing

    var body: some View {
        @Bindable var workshop = workshop

        Group {
            if workshop.isLoading {
                ProgressView("Loading workshop…")
            } else if let error = workshop.loadError {
                ContentUnavailableView {
                    Label("Workshop could not load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry", action: workshop.retry)
                }
            } else if workshop.rows.isEmpty {
                ContentUnavailableView(
                    "No open jobs", systemImage: "wrench.and.screwdriver",
                    description: Text(
                        "Start a job from a watch. Closed jobs remain in watch history."))
            } else {
                List(selection: selection) {
                    ForEach(JobStage.allCases.filter(\.isOpen), id: \.self) { stage in
                        let rows = workshop.rows(for: stage)
                        if !rows.isEmpty {
                            Section(stage.rawValue) {
                                ForEach(rows) { row in
                                    WorkshopJobRow(row: row).tag(row.id)
                                }
                            }
                        }
                    }
                }
                .accessibilityIdentifier("workshopJobList")
                .overlay {
                    if workshop.filteredRows.isEmpty {
                        ContentUnavailableView {
                            Label("No matching jobs", systemImage: "magnifyingglass")
                        } description: {
                            Text("Change the text or stage filter to see open jobs.")
                        } actions: {
                            Button("Clear Filters", action: workshop.clearFilters)
                        }
                    }
                }
            }
        }
        .navigationTitle("Workshop")
        .searchable(text: $workshop.searchText, prompt: "Find an open job")
        .toolbar {
            Picker("Job stage", selection: $workshop.stageFilter) {
                Text("All open stages").tag(JobStage?.none)
                ForEach(JobStage.allCases.filter(\.isOpen), id: \.self) { stage in
                    Text(stage.rawValue).tag(Optional(stage))
                }
            }
            .accessibilityIdentifier("workshopStageFilter")
        }
        .safeAreaInset(edge: .bottom) {
            if let error = workshop.navigationError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry", action: workshop.retry)
                }.padding()
            }
        }
        .disabled(editing.isSaving)
    }

    private var selection: Binding<UUID?> { Binding(get: selectedID, set: openJob) }
    private func selectedID() -> UUID? { editing.jobs.selectedID }
    private func openJob(_ id: UUID?) { workshop.open(id, editing: editing) }
}

private struct WorkshopJobRow: View {
    let row: WorkshopJob

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PhotoThumbnailView(photoID: row.watch.coverPhotoID).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.watch.name).font(.body).fontWeight(.semibold)
                Text(row.job.title).font(.subheadline)
                if let percentage = row.progress.percentage {
                    Text(
                        "\(row.progress.doneCount) of \(row.progress.countedCount) done · \(percentage)%"
                    )
                } else {
                    Text("No tasks planned")
                }
                Text(
                    "\(row.progress.skippedCount) skipped · \(row.unresolvedPartCount) unresolved parts"
                )
                if let reason = row.job.waitingReason {
                    Text("Waiting: \(reason)")
                }
            }
            .font(.subheadline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workshopJob-\(row.id.uuidString)")
    }
}
