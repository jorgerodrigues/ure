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
// fact saves as you type, with no Save or Cancel. An archived caliber reads like an archived
// watch, with Unarchive in the toolbar.
private struct CaliberPage: View {
    @Environment(CaliberState.self) private var calibers
    @Environment(WorkshopNavigation.self) private var navigation
    @Environment(WorkshopEditing.self) private var editing
    @Environment(\.undoManager) private var undoManager
    let caliber: CaliberRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PageLayout.sectionSpacing) {
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
        .toolbar {
            if caliber.archivedAt != nil {
                Button("Unarchive", action: unarchive)
                    .help("Unarchive Caliber")
                    .disabled(editing.isSaving)
                    .accessibilityIdentifier("unarchiveCaliber")
            }
        }
    }

    private func unarchive() {
        editing.requestNavigation { calibers.toggleArchiveCommand(undoManager: undoManager) }
    }
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
        HStack(alignment: .center, spacing: PageLayout.headerSpacing) {
            CaliberTile(caliberID: caliber.id)
            VStack(alignment: .leading, spacing: PageLayout.titleSpacing) {
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
                if let archivedAt = caliber.archivedAt {
                    ArchivedPill(
                        archivedAt: archivedAt, note: "Hidden from Calibers. Still in search.")
                } else {
                    Text(use)
                        .font(.system(size: InPlaceLayout.textSize))
                        .foregroundStyle(.secondary)
                }
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
        let open = jobs.jobs.filter { job in
            job.stage.isOpen && job.watchID.map(ids.contains) == true
        }.count
        let watchText = "In \(WatchWording.watches(used.count))"
        if open == 0 { return watchText }
        return "\(watchText) · \(open == 1 ? "1 job" : "\(open) jobs") open"
    }
}

// The caliber's first photo, or a gear when it has none.
private struct CaliberTile: View {
    @Environment(MaterialState.self) private var material
    let caliberID: UUID

    var body: some View {
        PageTile(photoID: photo?.id, symbol: "gearshape.2").accessibilityHidden(true)
    }

    private var photo: MaterialRecord? {
        material.records(for: .caliber(caliberID)).first { $0.item.kind == .photo }
    }
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
        VStack(alignment: .leading, spacing: PageLayout.factsTop) {
            Divider()
            VStack(alignment: .leading, spacing: PageLayout.factRowSpacing) {
                HStack(alignment: .top, spacing: PageLayout.factColumnSpacing) {
                    FactRow(field: facts.maker, isEditable: isEditable, identifier: "caliberMaker")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    FactPopUp(
                        field: facts.winding,
                        choices: Winding.allCases.map { FactPopUpChoice($0.rawValue) },
                        isEditable: isEditable, identifier: "caliberWinding"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    FactRow(
                        field: facts.beatRate, isEditable: isEditable, identifier: "caliberBeatRate"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .zIndex(1)
                HStack(alignment: .top, spacing: PageLayout.factColumnSpacing) {
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
        return WatchWording.watches(linkedWatches.count)
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

// Values from the "5 Caliber" artboard on the Paper page "Rework · Simple".
private enum CaliberPageLayout {
    static let listSpacing: CGFloat = 8
    static let listHeadingBottom: CGFloat = 4
    static let rowHeight: CGFloat = 52
    static let rowItemSpacing: CGFloat = 12
    static let thumbnailSize: CGFloat = 32
    static let thumbnailRadius: CGFloat = 8
    static let detailWidth: CGFloat = 200
    static let chevronWidth: CGFloat = 16
}
