import SwiftUI

struct WatchDetailView: View {
    @Environment(WatchState.self) private var watches
    @Environment(JobState.self) private var jobs
    @Environment(MaterialState.self) private var material

    var body: some View {
        if let watch = watches.selectedWatch,
            jobs.watchID == watch.id, jobs.selectedID != nil || jobs.draft != nil
        {
            JobDetailView()
        } else if let watch = watches.selectedWatch, material.isPresenting(on: .watch(watch.id)) {
            MaterialViewerView(page: .watch(watch.id))
        } else if let watch = watches.selectedWatch {
            WatchPage(watch: watch)
        } else {
            ContentUnavailableView {
                Label("Select a watch", systemImage: "watch.analog")
            } description: {
                Text(watches.saveError ?? "Choose a watch or add a new one.")
            }
        }
    }
}

// A watch page you write on, laid out as the "4 Watch" artboard: the header with the name as
// its title, the facts, the jobs, the material and the notes. Each fact saves as you type, with
// no Save or Cancel. An archived watch reads as "4b Archived watch", with Unarchive in the
// toolbar.
private struct WatchPage: View {
    @Environment(WatchState.self) private var watches
    @Environment(CaliberState.self) private var calibers
    @Environment(WorkshopNavigation.self) private var navigation
    @Environment(WorkshopEditing.self) private var editing
    @Environment(\.undoManager) private var undoManager
    let watch: WatchRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PageLayout.sectionSpacing) {
                if let facts = watches.facts(for: watch.id) {
                    WatchHeader(watch: watch, facts: facts)
                    WatchFactGrid(watch: watch, facts: facts).zIndex(1)
                }
                if let error = watches.saveError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                WatchJobs(watch: watch)
                MaterialSectionView(
                    owner: .watch(watch.id), caliber: calibers.caliber(watch.caliberID),
                    style: .page)
                NotesSectionView(owner: .watch(watch.id), style: .page, edited: watch.updatedAt)
            }
            .padding(.top, PageLayout.topPadding)
            .padding(.horizontal, PageLayout.sidePadding)
            .padding(.bottom, PageLayout.bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Each watch gets its own fields, so typing never reaches another watch's facts.
            .id(watch.id)
        }
        .textSelection(.enabled)
        .navigationTitle(navigation.selectedSection.title)
        .toolbar {
            if watch.archivedAt != nil {
                Button("Unarchive", action: unarchive)
                    .help("Unarchive Watch")
                    .disabled(editing.isSaving)
                    .accessibilityIdentifier("unarchiveWatch")
            }
        }
    }

    private func unarchive() {
        editing.requestNavigation { watches.toggleArchiveCommand(undoManager: undoManager) }
    }
}

// The watch's cover, its name as the title, and its open job or when it was archived. The
// name is written in place, and ⌘N puts the cursor there.
private struct WatchHeader: View {
    @Environment(WatchState.self) private var watches
    @Environment(WorkshopEditing.self) private var editing
    let watch: WatchRecord
    let facts: WatchFacts

    var body: some View {
        HStack(alignment: .center, spacing: PageLayout.headerSpacing) {
            WatchCover(watch: watch)
            VStack(alignment: .leading, spacing: PageLayout.titleSpacing) {
                InPlaceField(
                    field: facts.name, isEditable: isEditable, identifier: "watchName",
                    style: .title, requestsFocus: watches.nameToFocus == watch.id,
                    didFocus: watches.nameFocused
                )
                .padding(.leading, -InPlaceLayout.inset)
                if let archivedAt = watch.archivedAt {
                    ArchivedPill(
                        archivedAt: archivedAt, note: "Hidden from Watches. Still in search.")
                } else {
                    WatchOpenJobPill(watchID: watch.id)
                }
            }
        }
    }

    private var isEditable: Bool {
        editing.canWrite(.watch(watch.id)) && !watches.isSaving
    }
}

// The cover tile. Clicking it chooses a photo from the watch or its jobs as the cover.
private struct WatchCover: View {
    @Environment(MaterialState.self) private var material
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let watch: WatchRecord

    var body: some View {
        Menu {
            ForEach(choices) { photo in
                WatchCoverChoice(photo: photo, watchID: watch.id)
            }
            if !choices.isEmpty { Divider() }
            Button("Remove Cover", action: removeCover)
                .disabled(watch.coverPhotoID == nil)
        } label: {
            PageTile(photoID: watch.coverPhotoID, symbol: "watch.analog")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!canChoose)
        .help("Choose Cover")
        .accessibilityLabel("Cover")
        .accessibilityValue(watch.coverPhotoID == nil ? "None" : "Photo")
        .accessibilityIdentifier("watchCover")
    }

    // Photos from the watch's material and its jobs' material.
    private var choices: [MaterialRecord] {
        let jobIDs = Set(jobs.jobs.filter { $0.watchID == watch.id }.map(\.id))
        return material.records.filter { record in
            guard record.item.kind == .photo else { return false }
            if record.item.watchID == watch.id { return true }
            if let jobID = record.item.jobID { return jobIDs.contains(jobID) }
            return false
        }
    }

    private var canChoose: Bool {
        editing.canWrite(.watch(watch.id)) && !editing.isSaving && !material.isLoading
            && material.loadError == nil && !jobs.isLoading && jobs.loadError == nil
    }

    private func removeCover() { material.setCover(nil, for: watch.id) }
}

private struct WatchCoverChoice: View {
    @Environment(MaterialState.self) private var material
    let photo: MaterialRecord
    let watchID: UUID

    var body: some View {
        Button("\(photo.item.title) (\(photo.item.jobID == nil ? "Watch" : "Job"))", action: choose)
    }

    private func choose() { material.setCover(photo.id, for: watchID) }
}

// The watch's open job under its name. Clicking it opens the job.
private struct WatchOpenJobPill: View {
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let watchID: UUID

    var body: some View {
        if let job = jobs.openJob(for: watchID) {
            Button(action: open) {
                HStack(spacing: 6) {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    Text(job.title)
                        .font(.system(size: PageLayout.pillTextSize, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.leading, 9)
                .padding(.trailing, 10)
                .frame(height: WatchPageLayout.pillHeight)
                .background(Color.accentColor.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(editing.isSaving)
            .help("Open \(job.title)")
            .accessibilityLabel("Open job \(job.title)")
            .accessibilityValue(job.stage.rawValue)
            .accessibilityIdentifier("watchOpenJob")
        }
    }

    private func open() {
        guard let job = jobs.openJob(for: watchID) else { return }
        editing.requestNavigation { jobs.open(job) }
    }
}

// The eleven facts in three columns under a hairline: brand, model and reference; serial, year
// and caliber; case, diameter and lug width; owner and contact.
private struct WatchFactGrid: View {
    @Environment(WatchState.self) private var watches
    @Environment(CaliberState.self) private var calibers
    @Environment(WorkshopEditing.self) private var editing
    @Environment(WorkshopNavigation.self) private var navigation
    let watch: WatchRecord
    let facts: WatchFacts

    // While the watch archives, its facts can't change, so the archive's save covers them.
    var body: some View {
        let isEditable = editing.canWrite(.watch(watch.id)) && !watches.isSaving
        VStack(alignment: .leading, spacing: PageLayout.factsTop) {
            Divider()
            VStack(alignment: .leading, spacing: PageLayout.factRowSpacing) {
                WatchFactRow {
                    FactRow(field: facts.brand, isEditable: isEditable, identifier: "watchBrand")
                    FactRow(field: facts.model, isEditable: isEditable, identifier: "watchModel")
                    FactRow(
                        field: facts.reference, isEditable: isEditable,
                        identifier: "watchReference")
                }
                .zIndex(1)
                WatchFactRow {
                    FactRow(field: facts.serial, isEditable: isEditable, identifier: "watchSerial")
                    FactRow(field: facts.year, isEditable: isEditable, identifier: "watchYear")
                    FactPopUp(
                        field: facts.caliber, choices: caliberChoices, isEditable: isEditable,
                        identifier: "watchCaliber", open: openCaliber)
                }
                WatchFactRow {
                    FactRow(
                        field: facts.caseMaterial, isEditable: isEditable,
                        identifier: "watchCase")
                    FactRow(
                        field: facts.diameter, isEditable: isEditable,
                        identifier: "watchDiameter")
                    FactRow(
                        field: facts.lugWidth, isEditable: isEditable,
                        identifier: "watchLugWidth")
                }
                WatchFactRow {
                    FactRow(field: facts.owner, isEditable: isEditable, identifier: "watchOwner")
                    FactRow(
                        field: facts.contact, isEditable: isEditable, identifier: "watchContact")
                    Color.clear.frame(height: 0)
                }
            }
            .padding(.horizontal, -InPlaceLayout.inset)
        }
    }

    // Calibers that are not archived, by maker and name, and the watch's own caliber when it is
    // archived or no longer in the library.
    private var caliberChoices: [FactPopUpChoice] {
        var choices = calibers.activeCalibers.map {
            FactPopUpChoice(title: $0.title, value: $0.id.uuidString)
        }
        if let id = watch.caliberID, !choices.contains(where: { $0.value == id.uuidString }) {
            let title = calibers.caliber(id)?.title ?? "Unavailable caliber"
            choices.append(FactPopUpChoice(title: title, value: id.uuidString))
        }
        return choices
    }

    // Opens the watch's caliber on its own page.
    private func openCaliber() {
        guard let id = watch.caliberID, calibers.caliber(id) != nil else { return }
        editing.requestNavigation {
            editing.closeChildren()
            calibers.searchText = ""
            calibers.select(id)
            navigation.selection = .calibers
        }
    }
}

// Three facts side by side, each a third of the width.
private struct WatchFactRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: PageLayout.factColumnSpacing) {
            Group { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// The watch's jobs, newest first, with their state, task progress and dates. A watch with no
// open job can start one here.
private struct WatchJobs: View {
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let watch: WatchRecord

    var body: some View {
        VStack(alignment: .leading, spacing: WatchPageLayout.listSpacing) {
            PageSectionHeading(title: "Jobs", detail: count)
                .padding(.bottom, WatchPageLayout.listHeadingBottom)
            if jobs.isLoading {
                ProgressView("Loading jobs…")
            } else if let error = jobs.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Retry", action: retry)
            } else {
                if history.isEmpty {
                    Text("No jobs yet.").foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        Divider()
                        ForEach(history) { job in
                            WatchJobRow(job: job)
                            Divider()
                        }
                    }
                }
                if canStart {
                    Button("Start Job", systemImage: "plus", action: startJob)
                        .buttonStyle(.borderless)
                        .disabled(editing.isSaving)
                        .accessibilityIdentifier("startWatchJob")
                }
            }
        }
    }

    private var history: [JobRecord] { jobs.history(for: watch.id) }

    // Such as "2 jobs since 2021", or "1 job".
    private var count: String? {
        guard let oldest = history.last else { return nil }
        if history.count == 1 { return WatchWording.jobs(1) }
        let year = oldest.createdAt.formatted(.dateTime.year())
        return "\(WatchWording.jobs(history.count)) since \(year)"
    }

    private var canStart: Bool {
        watch.archivedAt == nil && jobs.openJob(for: watch.id) == nil
    }

    private func startJob() { editing.requestNavigation { jobs.start(for: watch.id) } }
    private func retry() { Task { await jobs.observe() } }
}

// A job on the watch page: its state, title, task progress and date. The row opens the job.
private struct WatchJobRow: View {
    @Environment(JobState.self) private var jobs
    @Environment(JobTaskState.self) private var tasks
    @Environment(WorkshopEditing.self) private var editing
    let job: JobRecord

    var body: some View {
        Button(action: open) {
            HStack(spacing: WatchPageLayout.rowItemSpacing) {
                JobStagePill(stage: job.stage)
                    .frame(width: WatchPageLayout.stageWidth, alignment: .leading)
                Text(job.title)
                    .font(.system(size: InPlaceLayout.textSize))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(progress)
                    .font(.system(size: PageLayout.detailSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: WatchPageLayout.progressWidth, alignment: .leading)
                Text(date)
                    .font(.system(size: PageLayout.detailSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: WatchPageLayout.dateWidth, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: WatchPageLayout.chevronWidth, alignment: .trailing)
            }
            .frame(height: WatchPageLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(editing.isSaving)
        .accessibilityLabel(job.title)
        .accessibilityValue("\(job.stage.rawValue), \(progress), \(date)")
        .accessibilityIdentifier("watchJob-\(job.id.uuidString)")
    }

    // Such as "6 of 10 done".
    private var progress: String {
        let progress = tasks.progress(for: job.id)
        guard progress.countedCount > 0 else { return "No tasks planned" }
        return "\(progress.doneCount) of \(progress.countedCount) done"
    }

    // An open job says since when, such as "Since 12 Oct". A closed job says when it closed.
    private var date: String {
        if job.stage.isOpen { return "Since \(ArchivedDate.short(job.createdAt))" }
        return ArchivedDate.short(job.completedAt ?? job.cancelledAt ?? job.updatedAt)
    }

    private func open() { editing.requestNavigation { jobs.open(job) } }
}

// A job's stage as a small pill. An open stage has the accent colour and a dot. A completed
// job has a tick.
struct JobStagePill: View {
    let stage: JobStage

    var body: some View {
        HStack(spacing: stage.isOpen ? 6 : 4) {
            if stage.isOpen {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            } else if stage == .completed {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
            }
            Text(stage.rawValue)
                .font(.system(size: PageLayout.pillTextSize, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(
            stage.isOpen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
        )
        .padding(.horizontal, 9)
        .frame(height: WatchPageLayout.stagePillHeight)
        .background(background, in: Capsule())
    }

    private var background: Color {
        if stage.isOpen { return Color.accentColor.opacity(0.1) }
        return Color(nsColor: .quaternarySystemFill)
    }
}

// Values from the "4 Watch" artboard on the Paper page "Rework · Simple".
private enum WatchPageLayout {
    static let pillHeight: CGFloat = 24
    static let stagePillHeight: CGFloat = 22
    static let listSpacing: CGFloat = 8
    static let listHeadingBottom: CGFloat = 4
    static let rowHeight: CGFloat = 48
    static let rowItemSpacing: CGFloat = 16
    static let stageWidth: CGFloat = 108
    static let progressWidth: CGFloat = 120
    static let dateWidth: CGFloat = 110
    static let chevronWidth: CGFloat = 16
}
