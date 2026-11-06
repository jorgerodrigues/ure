import SwiftUI

struct JobDetailView: View {
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    @Environment(WorkshopNavigation.self) private var navigation
    @Environment(MaterialState.self) private var material
    @Environment(PartState.self) private var parts

    var body: some View {
        Group {
            if let job = jobs.selectedJob, let part = parts.selectedPart, part.jobID == job.id {
                PartDetailView(showsBack: true)
            } else if let job = jobs.selectedJob, material.isPresenting(on: .job(job.id)) {
                MaterialViewerView(page: .job(job.id))
            } else if let job = jobs.selectedJob {
                JobPage(job: job).focusedSceneValue(\.recordBackAction, backAction)
            } else {
                ContentUnavailableView(
                    "Job unavailable", systemImage: "wrench.and.screwdriver",
                    description: Text("Choose another job."))
            }
        }
        .toolbar {
            // In Jobs the list holds the job, so only a job with a watch goes back to it.
            if hasWatchToGoBackTo {
                ToolbarItem(placement: .navigation) {
                    Button(RecordBack.watchTitle, systemImage: "chevron.left", action: backToWatch)
                        .accessibilityIdentifier("backToWatch")
                        .disabled(editing.isSaving)
                }
            }
        }
    }

    private var hasWatchToGoBackTo: Bool {
        navigation.selectedSection != .jobs && jobs.selectedJob?.watchID != nil
    }

    private var backAction: RecordBack? {
        guard !editing.isSaving, hasWatchToGoBackTo else { return nil }
        return RecordBack(title: RecordBack.watchTitle, action: backToWatch)
    }

    private func backToWatch() { editing.requestNavigation(jobs.close) }
}

// A job page you write on, laid out as the "2 Job" artboard: the header with the state, the
// title, the watch, its caliber and the owner, and the problem. Then come the parts, the
// checklist, the material and the notes. Everything saves as you type, with no Save or Cancel,
// and a Done job stays editable.
private struct JobPage: View {
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    @Environment(WatchState.self) private var watches
    @Environment(CaliberState.self) private var calibers
    @Environment(WorkshopNavigation.self) private var navigation
    let job: JobRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PageLayout.sectionSpacing) {
                if let facts = jobs.facts(for: job.id) {
                    JobHeader(job: job, facts: facts).zIndex(1)
                }
                if job.watchID == nil {
                    JobWatchFacts(job: job, isEditable: isEditable).zIndex(2)
                }
                if let error = jobs.refusal {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                PartSectionView(jobID: job.id).zIndex(1)
                ChecklistSectionView(jobID: job.id)
                MaterialSectionView(owner: .job(job.id), caliber: caliber, style: .page)
                NotesSectionView(owner: .job(job.id), style: .page, edited: job.updatedAt)
            }
            .padding(.top, PageLayout.topPadding)
            .padding(.horizontal, PageLayout.sidePadding)
            .padding(.bottom, PageLayout.bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Each job gets its own fields, so typing never reaches another job's facts.
            .id(job.id)
        }
        .textSelection(.enabled)
        .navigationTitle(navigation.selectedSection.title)
    }

    private var caliber: CaliberRecord? {
        calibers.caliber(watches.watches.first { $0.id == job.watchID }?.caliberID)
    }

    private var isEditable: Bool { editing.canWrite(.job(job.id)) && !jobs.isSaving }
}

// The cover, the state with when the job opened, the title, the line that links the watch and
// its caliber and names the owner, what a waiting job waits for, and the problem. The title is
// written in place, and starting a job puts the cursor there.
private struct JobHeader: View {
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    let job: JobRecord
    let facts: JobFacts

    var body: some View {
        VStack(alignment: .leading, spacing: JobPageLayout.headerSpacing) {
            HStack(alignment: .center, spacing: JobPageLayout.headerSpacing) {
                // A job without a watch has no cover yet, as on "6 New job".
                if job.watchID != nil { JobCover(job: job) }
                VStack(alignment: .leading, spacing: PageLayout.titleSpacing) {
                    HStack(spacing: JobPageLayout.stateSpacing) {
                        JobStatePopUp(job: job, isEditable: isEditable)
                        Text(JobWording.dates(of: job))
                            .font(.system(size: PageLayout.pillTextSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    InPlaceField(
                        field: facts.title, isEditable: isEditable, identifier: "jobTitle",
                        style: .title, requestsFocus: jobs.titleToFocus == job.id,
                        didFocus: jobs.titleFocused
                    )
                    .padding(.leading, -InPlaceLayout.inset)
                    JobLinks(job: job)
                }
            }
            if job.stage == .waiting {
                FactRow(
                    field: facts.waitingFor, isEditable: isEditable, identifier: "jobWaitingFor",
                    requestsFocus: jobs.waitingToFocus == job.id, didFocus: jobs.waitingFocused
                )
                .frame(maxWidth: NotesLayout.maximumWidth + 2 * InPlaceLayout.inset)
                .padding(.horizontal, -InPlaceLayout.inset)
            }
            JobProblem(field: facts.problem, isEditable: isEditable)
        }
    }

    // While the state changes, the job's fields wait for it.
    private var isEditable: Bool {
        editing.canWrite(.job(job.id)) && !jobs.isSaving
    }
}

// The cover of the job's watch, or the job's first photo when the watch has no cover.
private struct JobCover: View {
    @Environment(WatchState.self) private var watches
    @Environment(MaterialState.self) private var material
    let job: JobRecord

    var body: some View {
        PageTile(
            photoID: photoID, symbol: "watch.analog", size: JobPageLayout.tileSize,
            radius: JobPageLayout.tileRadius
        )
        .accessibilityHidden(true)
    }

    private var photoID: UUID? {
        if let cover = watches.watches.first(where: { $0.id == job.watchID })?.coverPhotoID {
            return cover
        }
        return material.records(for: .job(job.id)).first { $0.item.kind == .photo }?.id
    }
}

// The state as a pop-up. Choosing another state saves at once, and ⌘Z puts back the one before.
private struct JobStatePopUp: View {
    @Environment(JobState.self) private var jobs
    @Environment(\.undoManager) private var undoManager
    let job: JobRecord
    let isEditable: Bool

    var body: some View {
        Menu {
            Picker("State", selection: stage) {
                ForEach(JobStage.allCases, id: \.self) { stage in
                    Text(stage.rawValue).tag(stage)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            JobStagePill(stage: job.stage, showsIndicator: isEditable)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!isEditable)
        .help("Change State")
        .accessibilityLabel("State")
        .accessibilityValue(job.stage.rawValue)
        .accessibilityIdentifier("jobState")
    }

    private var stage: Binding<JobStage> { Binding(get: currentStage, set: choose) }
    private func currentStage() -> JobStage { job.stage }
    private func choose(_ stage: JobStage) {
        jobs.setStageCommand(stage, undoManager: undoManager)
    }
}

// The watch and its caliber, each opening its own page, then the owner and contact from the
// watch, such as "Grandfather's Seamaster › · Omega 552 › · Ana Ribeiro, +351 912 480 117".
private struct JobLinks: View {
    @Environment(WatchState.self) private var watches
    @Environment(CaliberState.self) private var calibers
    @Environment(JobState.self) private var jobs
    @Environment(WorkshopEditing.self) private var editing
    @Environment(WorkshopNavigation.self) private var navigation
    let job: JobRecord

    var body: some View {
        HStack(spacing: JobPageLayout.linkSpacing) {
            if let watch {
                JobLink(title: watch.name, identifier: "jobWatch", open: openWatch)
            }
            if let caliber {
                JobLinkSeparator()
                JobLink(title: caliber.title, identifier: "jobCaliber", open: openCaliber)
            }
            if let owner {
                JobLinkSeparator()
                Text(owner)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Owner")
                    .accessibilityValue(owner)
            }
        }
        .font(.system(size: PageLayout.detailSize))
    }

    private var watch: WatchRecord? { watches.watches.first { $0.id == job.watchID } }
    private var caliber: CaliberRecord? { calibers.caliber(watch?.caliberID) }

    // The owner and the contact, such as "Ana Ribeiro, +351 912 480 117".
    private var owner: String? {
        let parts = [watch?.owner, watch?.contact].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func openWatch() {
        guard let watchID = job.watchID else { return }
        editing.requestNavigation {
            editing.closeChildren()
            jobs.close()
            watches.searchText = ""
            watches.select(watchID)
            navigation.selection = .watches
        }
    }

    private func openCaliber() {
        guard let id = caliber?.id else { return }
        editing.requestNavigation {
            editing.closeChildren()
            calibers.searchText = ""
            calibers.select(id)
            navigation.selection = .calibers
        }
    }
}

private struct JobLink: View {
    @Environment(WorkshopEditing.self) private var editing
    let title: String
    let identifier: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: JobPageLayout.chevronSpacing) {
                Text(title).fontWeight(.medium).lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(editing.isSaving)
        .help("Open \(title)")
        .accessibilityLabel("Open \(title)")
        .accessibilityIdentifier(identifier)
    }
}

private struct JobLinkSeparator: View {
    var body: some View {
        Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
    }
}

// What is wrong with the watch, in the job's own words. It saves as you type, like the notes.
private struct JobProblem: View {
    let field: AutosaveField
    let isEditable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NotesTextView(
                field: field, text: field.text, isEditable: isEditable, label: "Problem",
                identifier: "jobProblem"
            )
            .frame(maxWidth: NotesLayout.maximumWidth, alignment: .leading)
            .overlay(alignment: .topLeading) {
                if field.text.isEmpty {
                    Text(isEditable ? "What’s wrong with it?" : "No problem written")
                        .font(.system(size: NotesLayout.textSize))
                        .foregroundStyle(.tertiary)
                        .frame(height: NotesLayout.lineHeight)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            if field.isEditing {
                Text("Saved as you type · Esc undoes this field")
                    .font(.system(size: NotesLayout.hintSize))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// How a job page words its dates.
enum JobWording {
    // When the job opened and how long ago, such as "Opened 12 October · 23 days", or when a
    // done job was done, such as "Opened 12 October · Done 2 November".
    static func dates(of job: JobRecord, now: Date = .now) -> String {
        let opened = "Opened \(PageLayout.day(job.createdAt, now: now))"
        if job.stage == .done, let doneAt = job.doneAt {
            return "\(opened) · Done \(PageLayout.day(doneAt, now: now))"
        }
        let calendar = Calendar.current
        let days =
            calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: job.createdAt),
                to: calendar.startOfDay(for: now)
            ).day ?? 0
        if days <= 0 { return "Opened today" }
        return "\(opened) · \(days == 1 ? "1 day" : "\(days) days")"
    }
}

// Values from the "2 Job" artboard on the Paper page "Rework · Simple": the Parts and Checklist
// headings sit 4 pt above their rows, which are 8 pt apart.
enum JobSectionLayout {
    static let spacing: CGFloat = 8
    static let headingBottom: CGFloat = 4
}

// Values from the "2 Job" artboard on the Paper page "Rework · Simple".
private enum JobPageLayout {
    static let tileSize: CGFloat = 88
    static let tileRadius: CGFloat = 16
    static let headerSpacing: CGFloat = 20
    static let stateSpacing: CGFloat = 10
    static let linkSpacing: CGFloat = 8
    static let chevronSpacing: CGFloat = 4
}
