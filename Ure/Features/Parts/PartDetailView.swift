import SwiftUI

// A part's own page: from the Parts list, or opened from its line on its job's page, which
// offers Back to Job.
struct PartDetailView: View {
    @Environment(PartState.self) private var parts
    @Environment(WorkshopEditing.self) private var editing
    @Environment(\.undoManager) private var undoManager
    var showsBack = false

    var body: some View {
        Group {
            if let part = parts.selectedPart {
                PartPage(part: part)
            } else if let error = parts.loadError {
                ContentUnavailableView {
                    Label("Parts unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry", action: retry)
                }
            } else {
                ContentUnavailableView("Part unavailable", systemImage: "shippingbox")
            }
        }
        .toolbar {
            if showsBack {
                ToolbarItem(placement: .navigation) {
                    Button(RecordBack.jobTitle, systemImage: "chevron.left", action: back)
                        .disabled(editing.isSaving).accessibilityIdentifier("backFromPart")
                }
            }
        }
        .focusedSceneValue(\.recordMenuActions, menuActions)
        .focusedSceneValue(\.recordBackAction, backAction)
    }

    private var menuActions: RecordMenuActions {
        guard let part = parts.selectedPart, !editing.isSaving, editing.canWrite(part) else {
            return RecordMenuActions()
        }
        return RecordMenuActions(remove: remove, removeTitle: PartState.removeActionName)
    }

    private var backAction: RecordBack? {
        guard showsBack, !editing.isSaving else { return nil }
        return RecordBack(title: RecordBack.jobTitle, action: back)
    }

    private func back() { editing.requestNavigation(parts.close) }
    private func retry() { Task { await parts.observe() } }

    private func remove() {
        guard let id = parts.selectedPart?.id else { return }
        parts.removeCommand(id, undoManager: undoManager)
    }
}

// The page you write a part on: its state, its name, its job and watch, its description and
// quantity, its saved links and its notes. Everything saves as you type.
private struct PartPage: View {
    @Environment(PartState.self) private var parts
    @Environment(WorkshopEditing.self) private var editing
    @Environment(WorkshopNavigation.self) private var navigation
    let part: PartRecord

    var body: some View {
        ScrollView {
            if let facts = parts.facts(for: part.id) {
                VStack(alignment: .leading, spacing: PageLayout.sectionSpacing) {
                    PartHeader(part: part, facts: facts, isEditable: isEditable).zIndex(1)
                    PartFactsRow(facts: facts, isEditable: isEditable)
                    if let error = parts.refusal {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                    PartLinksSection(links: parts.links(of: part.id))
                    PartNotesSection(
                        field: facts.notes, isEditable: isEditable, edited: part.updatedAt)
                }
                .padding(.top, PageLayout.topPadding)
                .padding(.horizontal, PageLayout.sidePadding)
                .padding(.bottom, PageLayout.bottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Each part gets its own fields, so typing never reaches another part's facts.
                .id(part.id)
            }
        }
        .textSelection(.enabled)
        .navigationTitle(navigation.selectedSection.title)
    }

    private var isEditable: Bool { editing.canWrite(part) }
}

// The state pop-up with the days the part reached, the name written in place, and its job and
// watch, or that it is a spare in the drawer.
private struct PartHeader: View {
    @Environment(PartState.self) private var parts
    let part: PartRecord
    let facts: PartFacts
    let isEditable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PartPageLayout.headerSpacing) {
            HStack(spacing: PartPageLayout.stateSpacing) {
                PartStatePopUp(part: part, isEditable: isEditable)
                Text(PartWording.days(of: part))
                    .font(.system(size: PageLayout.pillTextSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            InPlaceField(
                field: facts.name, isEditable: isEditable, identifier: "partTitle",
                style: .title, requestsFocus: parts.nameToFocus == part.id,
                didFocus: parts.nameFocused
            )
            .padding(.leading, -InPlaceLayout.inset)
            PartJobLinks(part: part)
        }
    }
}

// The state as a pop-up. Choosing another state saves at once, and ⌘Z puts back the one before
// with its days.
private struct PartStatePopUp: View {
    @Environment(PartState.self) private var parts
    @Environment(\.undoManager) private var undoManager
    let part: PartRecord
    let isEditable: Bool

    var body: some View {
        Menu {
            Picker("State", selection: stage) {
                ForEach(PartStage.allCases) { stage in
                    Text(stage.rawValue).tag(stage)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            PartStagePill(stage: part.stage, showsIndicator: isEditable)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!isEditable)
        .help("Change State")
        .accessibilityLabel("State")
        .accessibilityValue(part.stage.rawValue)
        .accessibilityIdentifier("partStatePopUp")
    }

    private var stage: Binding<PartStage> { Binding(get: currentStage, set: choose) }
    private func currentStage() -> PartStage { part.stage }
    private func choose(_ stage: PartStage) {
        parts.setStageCommand(stage, of: part.id, undoManager: undoManager)
    }
}

// The part's job and its watch, as one link that opens the job, such as "Full service,
// Grandfather's Seamaster ›", after the watch's cover. A spare says that it is in the drawer.
private struct PartJobLinks: View {
    @Environment(JobState.self) private var jobs
    @Environment(WatchState.self) private var watches
    @Environment(WorkshopEditing.self) private var editing
    @Environment(WorkshopNavigation.self) private var navigation
    let part: PartRecord

    var body: some View {
        HStack(spacing: PartPageLayout.linkSpacing) {
            if part.isSpare {
                PartSpareTile(size: PartPageLayout.linkTileSize)
                Text("Spare in the drawer")
                    .fontWeight(.medium)
            } else if let job {
                PhotoThumbnailView(photoID: watch?.coverPhotoID)
                    .frame(width: PartPageLayout.linkTileSize, height: PartPageLayout.linkTileSize)
                    .clipShape(RoundedRectangle(cornerRadius: PartPageLayout.linkTileRadius))
                    .accessibilityHidden(true)
                PartPageLink(title: title(of: job), identifier: "partJob", open: openJob)
            }
        }
        .font(.system(size: PageLayout.detailSize))
    }

    private var job: JobRecord? { jobs.jobs.first { $0.id == part.jobID } }
    private var watch: WatchRecord? { watches.watches.first { $0.id == job?.watchID } }

    private func title(of job: JobRecord) -> String {
        [job.title, watch?.name ?? "No watch yet"].joined(separator: ", ")
    }

    private func openJob() {
        guard let job else { return }
        editing.requestNavigation {
            editing.closeChildren()
            watches.select(job.watchID)
            jobs.open(job)
            if navigation.selectedSection != .watches || job.watchID == nil {
                navigation.selection = .jobs
            }
        }
    }
}

// The description and the quantity, under a thin line, as on "3 Parts". The description can
// take several lines.
private struct PartFactsRow: View {
    let facts: PartFacts
    let isEditable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.bottom, PartPageLayout.factsTop)
            HStack(alignment: .top, spacing: PageLayout.factColumnSpacing) {
                VStack(alignment: .leading, spacing: InPlaceLayout.labelSpacing) {
                    Text("Description")
                        .font(.system(size: InPlaceLayout.labelSize, weight: .medium))
                        .foregroundStyle(
                            facts.description.isEditing ? Color.accentColor : .secondary
                        )
                        .accessibilityHidden(true)
                    NotesTextView(
                        field: facts.description, text: facts.description.text,
                        isEditable: isEditable, label: "Description",
                        identifier: "partDescription"
                    )
                    .overlay(alignment: .topLeading) {
                        if facts.description.text.isEmpty {
                            Text(isEditable ? "Add a description" : "No description")
                                .font(.system(size: NotesLayout.textSize))
                                .foregroundStyle(.tertiary)
                                .frame(height: NotesLayout.lineHeight)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(3)
                FactRow(field: facts.quantity, isEditable: isEditable, identifier: "partQuantity")
                    .padding(.leading, -InPlaceLayout.inset)
                    .frame(width: PartPageLayout.quantityWidth, alignment: .leading)
            }
        }
    }
}

// The drawer that marks a spare, on a grey tile, as on "3 Parts".
struct PartSpareTile: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * PartListLayout.tileRadius / PartListLayout.tileSize)
            .fill(Color(nsColor: .quaternarySystemFill))
            .overlay {
                Image(systemName: PartListLayout.spareSymbol)
                    .font(.system(size: size * PartListLayout.symbolSize / PartListLayout.tileSize))
                    .foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
            .accessibilityLabel("Spare")
    }
}

private struct PartPageLink: View {
    @Environment(WorkshopEditing.self) private var editing
    let title: String
    let identifier: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: PartPageLayout.chevronSpacing) {
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

// The links saved on the part, such as listings and identification references. Each opens in
// the default browser only when you click Open. W041 turns them into buying options.
private struct PartLinksSection: View {
    @Environment(PartState.self) private var parts
    let links: [PartLink]

    var body: some View {
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: PageLayout.headingSpacing) {
                PageSectionHeading(title: "Links", detail: "\(links.count)")
                ForEach(links) { link in
                    HStack(spacing: PartPageLayout.linkSpacing) {
                        Image(systemName: "link").foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(link.url).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 12)
                        Button("Open") { parts.openLink(link) }
                            .accessibilityLabel("Open \(link.url) in browser")
                            .accessibilityIdentifier("openPartLink-\(link.id.uuidString)")
                    }
                    .font(.system(size: PageLayout.detailSize))
                    .frame(maxWidth: NotesLayout.maximumWidth)
                }
                if let error = parts.openError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
    }
}

// The part's notes, which save as you type like a job's.
private struct PartNotesSection: View {
    let field: AutosaveField
    let isEditable: Bool
    let edited: Date

    var body: some View {
        VStack(alignment: .leading, spacing: PageLayout.headingSpacing) {
            PageSectionHeading(title: "Notes", detail: "Edited \(PageLayout.day(edited))")
            NotesTextView(
                field: field, text: field.text, isEditable: isEditable, label: "Notes",
                identifier: "partNotes"
            )
            .frame(maxWidth: NotesLayout.maximumWidth, alignment: .leading)
            .overlay(alignment: .topLeading) {
                if field.text.isEmpty {
                    Text(isEditable ? "Where it came from, what it fits…" : "No notes")
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

// Values from the "3 Parts" artboard on the Paper page "Rework · Simple".
private enum PartPageLayout {
    static let headerSpacing: CGFloat = 8
    static let stateSpacing: CGFloat = 10
    static let linkSpacing: CGFloat = 8
    static let linkTileSize: CGFloat = 20
    static let linkTileRadius: CGFloat = 4
    static let chevronSpacing: CGFloat = 4
    static let factsTop: CGFloat = 20
    static let quantityWidth: CGFloat = 154
}
