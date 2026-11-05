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
                    HStack(alignment: .top, spacing: PageLayout.factColumnSpacing) {
                        FactRow(
                            field: facts.description, isEditable: isEditable,
                            identifier: "partDescription"
                        )
                        .frame(maxWidth: NotesLayout.maximumWidth)
                        FactRow(
                            field: facts.quantity, isEditable: isEditable,
                            identifier: "partQuantity"
                        )
                        .frame(width: PartPageLayout.quantityWidth)
                    }
                    .padding(.horizontal, -InPlaceLayout.inset)
                    if let error = parts.saveError {
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
        VStack(alignment: .leading, spacing: PageLayout.titleSpacing) {
            HStack(spacing: PartPageLayout.stateSpacing) {
                PartStatePopUp(part: part, isEditable: isEditable)
                if let days = PartWording.days(of: part) {
                    Text(days)
                        .font(.system(size: PageLayout.pillTextSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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

// The job and its watch, each opening its own page, such as "Full service › · Grandfather's
// Seamaster ›". A spare says that it is in the drawer.
private struct PartJobLinks: View {
    @Environment(PartState.self) private var parts
    @Environment(JobState.self) private var jobs
    @Environment(WatchState.self) private var watches
    @Environment(WorkshopEditing.self) private var editing
    @Environment(WorkshopNavigation.self) private var navigation
    let part: PartRecord

    var body: some View {
        HStack(spacing: PartPageLayout.linkSpacing) {
            if part.isSpare {
                Label("Spare in the drawer", systemImage: PartListLayout.spareSymbol)
                    .foregroundStyle(.secondary)
            } else {
                if let job {
                    PartPageLink(title: job.title, identifier: "partJob", open: openJob)
                }
                if let watch {
                    Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
                    PartPageLink(title: watch.name, identifier: "partWatch", open: openWatch)
                } else if job != nil {
                    Text("· No watch yet").foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: PageLayout.detailSize))
    }

    private var job: JobRecord? { jobs.jobs.first { $0.id == part.jobID } }
    private var watch: WatchRecord? { watches.watches.first { $0.id == job?.watchID } }

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

    private func openWatch() {
        guard let watchID = watch?.id else { return }
        editing.requestNavigation {
            editing.closeChildren()
            jobs.close()
            watches.searchText = ""
            watches.select(watchID)
            navigation.selection = .watches
        }
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
            if let error = field.saveError {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Label {
                        Text("The notes did not save. Your text is still here. \(error)")
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                    .font(.system(size: NotesLayout.failureSize))
                    .foregroundStyle(.red)
                    Button("Try Again", action: field.saveNow)
                        .controlSize(.small)
                }
                .accessibilityElement(children: .contain)
            } else if field.isEditing {
                Text("Saved as you type · Esc undoes this field")
                    .font(.system(size: NotesLayout.hintSize))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private enum PartPageLayout {
    static let stateSpacing: CGFloat = 10
    static let linkSpacing: CGFloat = 8
    static let chevronSpacing: CGFloat = 4
    static let quantityWidth: CGFloat = 120
}
