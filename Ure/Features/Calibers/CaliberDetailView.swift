import SwiftUI

struct CaliberDetailView: View {
    @Environment(CaliberState.self) private var calibers
    @Environment(MaterialState.self) private var material

    var body: some View {
        if let caliber = calibers.selectedCaliber, material.isPresenting(on: .caliber(caliber.id)) {
            MaterialViewerView(page: .caliber(caliber.id))
        } else if let caliber = calibers.selectedCaliber {
            CaliberPage(caliber: caliber)
        } else {
            ContentUnavailableView {
                Label("Select a caliber", systemImage: "gearshape.2")
            } description: {
                Text(calibers.saveError ?? "Choose a caliber or add a new one.")
            }
        }
    }
}

// A caliber page you write on, laid out as the "5 Caliber" artboard: the header with the name
// as its title, the facts, the watches that use the caliber, its material and its notes. Each
// fact saves as you type, with no Save or Cancel.
private struct CaliberPage: View {
    @Environment(CaliberState.self) private var calibers
    @Environment(WorkshopNavigation.self) private var navigation
    let caliber: CaliberRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PageLayout.sectionSpacing) {
                if caliber.archivedAt != nil {
                    CaliberArchivedNotice()
                }
                if let facts = calibers.facts(for: caliber.id) {
                    CaliberHeader(caliber: caliber, facts: facts)
                    CaliberFactGrid(caliberID: caliber.id, facts: facts).zIndex(1)
                }
                if let error = calibers.saveError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                CaliberWatches(caliberID: caliber.id)
                MaterialSectionView(owner: .caliber(caliber.id), style: .page)
                NotesSectionView(
                    owner: .caliber(caliber.id), style: .page, edited: caliber.updatedAt)
            }
            .padding(.top, PageLayout.topPadding)
            .padding(.horizontal, PageLayout.sidePadding)
            .padding(.bottom, PageLayout.bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Each caliber gets its own fields, so typing never reaches another caliber's facts.
            .id(caliber.id)
        }
        .textSelection(.enabled)
        .navigationTitle(navigation.selectedSection.title)
    }
}

private struct CaliberArchivedNotice: View {
    @Environment(CaliberState.self) private var calibers
    @Environment(WorkshopEditing.self) private var editing

    var body: some View {
        HStack {
            Label("Archived. Unarchive to make changes.", systemImage: "archivebox")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Unarchive Caliber", action: unarchive)
                .disabled(editing.isSaving)
                .accessibilityIdentifier("archiveCaliber")
        }
    }

    private func unarchive() { editing.requestNavigation(calibers.toggleArchiveCommand) }
}

// The caliber's photo, its maker and name as the title, and where it is used. The name is
// written in place, and ⌘N puts the cursor there.
private struct CaliberHeader: View {
    @Environment(CaliberState.self) private var calibers
    @Environment(WorkshopEditing.self) private var editing
    @Environment(WatchState.self) private var watches
    @Environment(JobState.self) private var jobs
    let caliber: CaliberRecord
    let facts: CaliberFacts

    var body: some View {
        HStack(alignment: .center, spacing: CaliberPageLayout.headerSpacing) {
            CaliberTile(caliberID: caliber.id)
            VStack(alignment: .leading, spacing: CaliberPageLayout.titleSpacing) {
                HStack(alignment: .center, spacing: 0) {
                    if let maker = caliber.manufacturer {
                        Text(maker + " ")
                            .font(.system(size: InPlaceLayout.titleSize, weight: .bold))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    InPlaceField(
                        field: facts.name, isEditable: isEditable, identifier: "caliberName",
                        style: .title, requestsFocus: calibers.nameToFocus == caliber.id,
                        didFocus: calibers.nameFocused
                    )
                    .padding(.leading, -InPlaceLayout.inset)
                }
                Text(use)
                    .font(.system(size: InPlaceLayout.textSize))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isEditable: Bool {
        editing.canWrite(.caliber(caliber.id)) && !calibers.isSaving
    }

    // Where the caliber is used, such as "In 2 watches · 1 job open".
    private var use: String {
        let used = watches.watches.filter { $0.caliberID == caliber.id }
        guard !used.isEmpty else { return "No watches yet" }
        let ids = Set(used.map(\.id))
        let open = jobs.jobs.filter { ids.contains($0.watchID) && $0.stage.isOpen }.count
        let watchText = "In \(CaliberWording.watches(used.count))"
        if open == 0 { return watchText }
        return "\(watchText) · \(open == 1 ? "1 job" : "\(open) jobs") open"
    }
}

// The caliber's first photo, or a gear when it has none.
private struct CaliberTile: View {
    @Environment(MaterialState.self) private var material
    let caliberID: UUID

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .quaternarySystemFill))
            if let photo = material.records(for: .caliber(caliberID)).first(where: isPhoto) {
                PhotoThumbnailView(photoID: photo.id, fills: true)
            } else {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: CaliberPageLayout.tileSize, height: CaliberPageLayout.tileSize)
        .clipShape(RoundedRectangle(cornerRadius: CaliberPageLayout.tileRadius))
        .overlay(
            RoundedRectangle(cornerRadius: CaliberPageLayout.tileRadius)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }

    private func isPhoto(_ record: MaterialRecord) -> Bool { record.item.kind == .photo }
}

// The six facts in three columns under a hairline: maker, winding and beat rate, then jewels,
// power reserve and lift angle.
private struct CaliberFactGrid: View {
    @Environment(CaliberState.self) private var calibers
    @Environment(WorkshopEditing.self) private var editing
    let caliberID: UUID
    let facts: CaliberFacts

    // While the caliber archives, its facts can't change, so the archive's save covers them.
    var body: some View {
        let isEditable = editing.canWrite(.caliber(caliberID)) && !calibers.isSaving
        VStack(alignment: .leading, spacing: CaliberPageLayout.factsTop) {
            Divider()
            VStack(alignment: .leading, spacing: CaliberPageLayout.rowSpacing) {
                HStack(alignment: .top, spacing: CaliberPageLayout.columnSpacing) {
                    FactRow(field: facts.maker, isEditable: isEditable, identifier: "caliberMaker")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    FactPopUp(
                        field: facts.winding, choices: Winding.allCases.map(\.rawValue),
                        isEditable: isEditable, identifier: "caliberWinding"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    FactRow(
                        field: facts.beatRate, isEditable: isEditable, identifier: "caliberBeatRate"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .zIndex(1)
                HStack(alignment: .top, spacing: CaliberPageLayout.columnSpacing) {
                    FactRow(
                        field: facts.jewels, isEditable: isEditable, identifier: "caliberJewels"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    FactRow(
                        field: facts.powerReserve, isEditable: isEditable,
                        identifier: "caliberPowerReserve"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    FactRow(
                        field: facts.liftAngle, isEditable: isEditable,
                        identifier: "caliberLiftAngle"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, -InPlaceLayout.inset)
        }
    }
}

private struct CaliberWatches: View {
    @Environment(WatchState.self) private var watches
    let caliberID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: CaliberPageLayout.listSpacing) {
            PageSectionHeading(title: "Watches", detail: count)
                .padding(.bottom, CaliberPageLayout.listHeadingBottom)
            if watches.isLoading {
                ProgressView("Loading watches…")
            } else if let error = watches.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Retry", action: retry)
            } else if linkedWatches.isEmpty {
                Text("No watches use this caliber yet.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    Divider()
                    ForEach(linkedWatches) { watch in
                        CaliberWatchRow(watch: watch)
                        Divider()
                    }
                }
            }
        }
    }

    private var linkedWatches: [WatchRecord] {
        watches.watches.filter { $0.caliberID == caliberID }
    }

    private var count: String? {
        if linkedWatches.isEmpty { return nil }
        return CaliberWording.watches(linkedWatches.count)
    }

    private func retry() {
        Task { await watches.observe() }
    }
}

// A watch that uses the caliber: its cover, its name, and its brand, year and open job. The
// row opens the watch.
private struct CaliberWatchRow: View {
    @Environment(WatchState.self) private var watches
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopNavigation.self) private var navigation
    @Environment(WorkshopEditing.self) private var editing
    let watch: WatchRecord

    var body: some View {
        Button(action: openWatch) {
            HStack(spacing: CaliberPageLayout.rowItemSpacing) {
                CaliberWatchThumbnail(photoID: watch.coverPhotoID)
                Text(watch.name)
                    .font(.system(size: InPlaceLayout.textSize))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(detail)
                    .font(.system(size: PageLayout.detailSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: CaliberPageLayout.detailWidth, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: CaliberPageLayout.chevronWidth, alignment: .trailing)
            }
            .frame(height: CaliberPageLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(watch.name)
        .accessibilityValue(detail)
        .accessibilityIdentifier("caliberWatch-\(watch.id)")
    }

    // Such as "Omega · 1958 · In progress".
    private var detail: String {
        [watch.brand, watch.approximateYear, jobs.openJob(for: watch.id)?.stage.rawValue]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func openWatch() {
        editing.requestNavigation {
            editing.jobs.close()
            watches.searchText = ""
            watches.select(watch.id)
            navigation.selection = .watches
        }
    }
}

private struct CaliberWatchThumbnail: View {
    let photoID: UUID?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .quaternarySystemFill))
            if let photoID {
                PhotoThumbnailView(photoID: photoID, fills: true)
            } else {
                Image(systemName: "watch.analog")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: CaliberPageLayout.thumbnailSize, height: CaliberPageLayout.thumbnailSize)
        .clipShape(RoundedRectangle(cornerRadius: CaliberPageLayout.thumbnailRadius))
        .accessibilityHidden(true)
    }
}

enum CaliberWording {
    static func watches(_ count: Int) -> String {
        count == 1 ? "1 watch" : "\(count) watches"
    }
}

// Values from the "5 Caliber" artboard on the Paper page "Rework · Simple".
private enum CaliberPageLayout {
    static let tileSize: CGFloat = 104
    static let tileRadius: CGFloat = 18
    static let headerSpacing: CGFloat = 24
    static let titleSpacing: CGFloat = 6
    static let factsTop: CGFloat = 24
    static let rowSpacing: CGFloat = 20
    static let columnSpacing: CGFloat = 32
    static let listSpacing: CGFloat = 8
    static let listHeadingBottom: CGFloat = 4
    static let rowHeight: CGFloat = 52
    static let rowItemSpacing: CGFloat = 12
    static let thumbnailSize: CGFloat = 32
    static let thumbnailRadius: CGFloat = 8
    static let detailWidth: CGFloat = 200
    static let chevronWidth: CGFloat = 16
}
