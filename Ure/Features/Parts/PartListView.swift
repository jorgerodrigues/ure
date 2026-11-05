import SwiftUI

// The Parts list, laid out as the "3 Parts" artboard: To buy, Ordered and In hand, each part
// with its job's watch, or the drawer for a spare. The toolbar says how many are to buy and
// ordered, such as "2 to buy · 2 ordered".
struct PartListView: View {
    @Environment(PartListState.self) private var partList
    @Environment(PartState.self) private var parts
    @Environment(WorkshopEditing.self) private var editing
    @Environment(SearchState.self) private var search

    var body: some View {
        @Bindable var partList = partList

        Group {
            if partList.isLoading {
                ProgressView("Loading parts…")
            } else if let error = partList.loadError {
                ContentUnavailableView {
                    Label("Parts could not load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry", action: partList.retry)
                }
            } else if partList.rows.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to buy", systemImage: WorkshopSection.parts.symbol)
                } description: {
                    Text(
                        "Add parts on a job’s page, or keep a spare in the drawer. Fitted parts stay on their job’s page."
                    )
                } actions: {
                    Button(NewRecord.title(in: .parts), action: newPart)
                }
            } else {
                List(selection: selection) {
                    ForEach(PartListGroup.allCases, id: \.self) { group in
                        let rows = partList.rows(in: group)
                        if !rows.isEmpty {
                            Section(group.title) {
                                ForEach(rows) { row in
                                    PartListRowView(row: row).tag(row.id)
                                        .listRowSeparator(.hidden)
                                        .contextMenu {
                                            PartMenuButtons(
                                                part: row.part,
                                                isEditable: editing.canWrite(row.part),
                                                opens: false)
                                        }
                                }
                            }
                        }
                    }
                }
                .accessibilityIdentifier("partList")
                .overlay {
                    if partList.filteredRows.isEmpty {
                        ContentUnavailableView.search(text: partList.searchText)
                    }
                }
            }
        }
        .navigationTitle(WorkshopSection.parts.title)
        .navigationSubtitle(partList.subtitle)
        .toolbarSearch(text: $partList.searchText)
        .toolbar { NewRecordButton(section: .parts) }
        .disabled(editing.isSaving)
    }

    private var selection: Binding<UUID?> { Binding(get: selectedID, set: openPart) }
    private func selectedID() -> UUID? { parts.selectedID }

    // Clicking a heading or an empty part of the list keeps the selected part.
    private func openPart(_ id: UUID?) {
        guard let id, id != parts.selectedID else { return }
        editing.requestNavigation { parts.select(id) }
    }

    private func newPart() { NewRecord.make(in: .parts, editing: editing, search: search) }
}

// A part in the list: its job's watch's cover, or the drawer for a spare, its name, and a line
// such as "Grandfather's Seamaster · Full service" or "Spare".
private struct PartListRowView: View {
    let row: PartListRow

    var body: some View {
        HStack(spacing: UreLayout.rowSpacing) {
            tile.frame(width: UreLayout.rowThumbnailSize, height: UreLayout.rowThumbnailSize)
            VStack(alignment: .leading, spacing: UreLayout.textSpacing) {
                Text(row.part.name)
                    .font(.body)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(PartListWording.detail(of: row))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("partListRow-\(row.id.uuidString)")
    }

    @ViewBuilder private var tile: some View {
        if row.part.isSpare {
            RoundedRectangle(cornerRadius: PartListLayout.tileRadius)
                .fill(Color(nsColor: .quaternarySystemFill))
                .overlay {
                    Image(systemName: PartListLayout.spareSymbol)
                        .font(.system(size: PartListLayout.symbolSize))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Spare")
        } else if let watch = row.watch {
            PhotoThumbnailView(photoID: watch.coverPhotoID)
        } else {
            RoundedRectangle(cornerRadius: PartListLayout.tileRadius)
                .strokeBorder(
                    Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                )
                .accessibilityHidden(true)
        }
    }
}

enum PartListLayout {
    // The drawer that marks a spare.
    static let spareSymbol = "cabinet"
    static let tileRadius: CGFloat = 8
    static let symbolSize: CGFloat = 15
}
