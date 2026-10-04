import SwiftUI

struct PartsOverviewView: View {
    @Environment(PartsOverviewState.self) private var overview
    @Environment(WorkshopEditing.self) private var editing

    var body: some View {
        @Bindable var overview = overview

        Group {
            if overview.isLoading {
                ProgressView("Loading parts…")
            } else if let error = overview.loadError {
                ContentUnavailableView {
                    Label("Parts could not load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry", action: overview.retry)
                }
            } else if overview.rows.isEmpty {
                ContentUnavailableView(
                    "No required parts", systemImage: "shippingbox",
                    description: Text(
                        "Add parts to an open job. Closed parts remain in watch history.")
                )
            } else {
                List(selection: selection) {
                    ForEach(overview.filteredRows) { row in
                        OverviewPartRow(row: row).tag(row.id)
                    }
                }
                .accessibilityIdentifier("partsOverviewList")
                .overlay {
                    if overview.filteredRows.isEmpty {
                        ContentUnavailableView {
                            Label("No matching parts", systemImage: "magnifyingglass")
                        } description: {
                            Text("Change the text or status filter to see parts from open jobs.")
                        } actions: {
                            Button("Clear Filters", action: overview.clearFilters)
                        }
                    }
                }
            }
        }
        .navigationTitle("Parts")
        .searchable(text: $overview.searchText, prompt: "Find a part, watch, or job")
        .toolbar {
            Picker("Part status", selection: $overview.statusFilter) {
                Text("All statuses").tag(PartStatus?.none)
                ForEach(PartStatus.allCases) { status in
                    Text(status.rawValue).tag(Optional(status))
                }
            }
            .accessibilityIdentifier("partsStatusFilter")
        }
        .safeAreaInset(edge: .bottom) {
            if let error = overview.navigationError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry", action: overview.retry)
                }.padding()
            }
        }
        .disabled(editing.isSaving)
    }

    private var selection: Binding<UUID?> { Binding(get: selectedID, set: openPart) }
    private func selectedID() -> UUID? { overview.selectedID(editing: editing) }
    private func openPart(_ id: UUID?) { overview.open(id, editing: editing) }
}

private struct OverviewPartRow: View {
    let row: OverviewPart

    var body: some View {
        HStack(alignment: .top, spacing: UreLayout.rowSpacing) {
            PhotoThumbnailView(photoID: row.watch.coverPhotoID)
                .frame(width: UreLayout.rowThumbnailSize, height: UreLayout.rowThumbnailSize)
            VStack(alignment: .leading, spacing: UreLayout.textSpacing) {
                Text(row.part.description).font(.body).fontWeight(.semibold)
                if let reference = row.part.manufacturerReference {
                    Text("Reference: \(reference)")
                }
                Text("Watch: \(row.watch.name)")
                Text("Job: \(row.job.title) · \(row.job.stage.rawValue)")
                Text("\(row.part.status.rawValue) · Quantity \(row.part.quantity)")
            }
            .font(.subheadline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("overviewPart-\(row.id.uuidString)")
    }
}
