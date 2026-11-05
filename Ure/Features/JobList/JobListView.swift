import SwiftUI

// The Jobs list, laid out as the "6 New job" artboard: In progress, Waiting and Done recently,
// each job once, with its watch's cover, its watch's name and a line about the work.
struct JobListView: View {
    @Environment(JobListState.self) private var jobList
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    @Environment(WorkshopNavigation.self) private var navigation
    @Environment(SearchState.self) private var search

    var body: some View {
        @Bindable var jobList = jobList

        Group {
            if jobList.isLoading {
                ProgressView("Loading jobs…")
            } else if let error = jobList.loadError {
                ContentUnavailableView {
                    Label("Jobs could not load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry", action: jobList.retry)
                }
            } else if jobList.listedRows.isEmpty {
                ContentUnavailableView {
                    Label("No jobs", systemImage: WorkshopSection.jobs.symbol)
                } description: {
                    Text("Start a job and pick its watch. Older jobs stay on their watch’s page.")
                } actions: {
                    Button(NewRecord.title(in: .jobs), action: newJob)
                }
            } else {
                List(selection: selection) {
                    ForEach(JobListGroup.allCases, id: \.self) { group in
                        let rows = jobList.rows(in: group)
                        if !rows.isEmpty {
                            Section(group.title) {
                                ForEach(rows) { row in
                                    JobListRowView(row: row).tag(row.id)
                                        .listRowSeparator(.hidden)
                                }
                            }
                        }
                    }
                }
                .accessibilityIdentifier("jobList")
                .overlay {
                    if jobList.filteredRows.isEmpty {
                        ContentUnavailableView.search(text: jobList.searchText)
                    }
                }
            }
        }
        .navigationTitle(WorkshopSection.jobs.title)
        .navigationSubtitle(jobList.subtitle)
        .toolbarSearch(text: $jobList.searchText)
        .toolbar { NewRecordButton(section: .jobs) }
        .safeAreaInset(edge: .bottom) {
            if let error = jobList.navigationError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry", action: jobList.retry)
                }.padding()
            }
        }
        .disabled(editing.isSaving)
    }

    private var selection: Binding<UUID?> { Binding(get: selectedID, set: openJob) }
    private func selectedID() -> UUID? { jobs.selectedID }

    // Clicking a heading or an empty part of the list keeps the selected job.
    private func openJob(_ id: UUID?) {
        guard let id, id != jobs.selectedID else { return }
        jobList.open(id, editing: editing)
    }

    private func newJob() {
        NewRecord.make(in: .jobs, editing: editing, navigation: navigation, search: search)
    }
}

// A job in the list: its watch's cover, its watch's name, and its title with the progress, such
// as "Full service · 6 of 10 · 1 to buy". A job without a watch shows its title and
// "No watch yet" beside an empty dashed tile.
private struct JobListRowView: View {
    let row: JobListRow

    var body: some View {
        HStack(spacing: UreLayout.rowSpacing) {
            if let watch = row.watch {
                PhotoThumbnailView(photoID: watch.coverPhotoID)
                    .frame(width: UreLayout.rowThumbnailSize, height: UreLayout.rowThumbnailSize)
            } else {
                RoundedRectangle(cornerRadius: JobListLayout.tileRadius)
                    .strokeBorder(
                        Color.secondary.opacity(0.6),
                        style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                    )
                    .frame(width: UreLayout.rowThumbnailSize, height: UreLayout.rowThumbnailSize)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: UreLayout.textSpacing) {
                Text(JobListWording.title(of: row))
                    .font(.body)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(JobListWording.detail(of: row))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("jobListRow-\(row.id.uuidString)")
    }
}

// Values from the "6 New job" artboard on the Paper page "Rework · Simple".
private enum JobListLayout {
    static let tileRadius: CGFloat = 8
}
