import SwiftUI

// The job's parts under the Parts heading, laid out as on the "2 Job" artboard. Each part is one
// line: its state, its name written in place, its description and quantity, and the day of its
// state. A click on the state moves the part on and records the day. The line after the last
// part adds the next one as you type, as on the "7 Typing" artboard, and offers the spares in
// hand whose name matches. Parts and checklist steps are independent.
struct PartSectionView: View {
    @Environment(PartState.self) private var parts
    @Environment(WorkshopEditing.self) private var editing
    let jobID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: JobSectionLayout.spacing) {
            PageSectionHeading(title: "Parts", detail: summary)
                .padding(.bottom, JobSectionLayout.headingBottom)
            content
        }
    }

    // How many of the job's parts are still to buy, such as "1 to buy".
    private var summary: String? {
        guard !parts.isLoading, parts.loadError == nil else { return nil }
        let toBuy = parts.parts(on: jobID).filter { $0.stage == .needed }.count
        return toBuy > 0 ? "\(toBuy) to buy" : nil
    }

    @ViewBuilder private var content: some View {
        if parts.isLoading {
            ProgressView("Loading parts…")
        } else if let error = parts.loadError {
            Label(error, systemImage: "exclamationmark.triangle")
            Button("Retry", action: retry)
        } else {
            PartLines(
                jobID: jobID, lines: parts.parts(on: jobID),
                isEditable: editing.canWrite(.job(jobID)))
        }
    }

    private func retry() { Task { await parts.observe() } }
}

private struct PartLines: View {
    @Environment(PartState.self) private var state
    let jobID: UUID
    let lines: [PartRecord]
    let isEditable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { part in
                PartLine(part: part, isEditable: isEditable)
            }
            if isEditable {
                PartEntryLine(entry: state.entry(for: jobID))
            } else if lines.isEmpty {
                Text("No parts").foregroundStyle(.secondary)
            }
            if let error = state.saveError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: NotesLayout.failureSize))
                    .foregroundStyle(.red)
                    .padding(.top, PartLineLayout.messageTop)
            }
        }
    }
}

// One part: its state, which a click moves on, its name written in place, its description and
// quantity, the day of its state, and an arrow that opens its page.
private struct PartLine: View {
    @Environment(PartState.self) private var parts
    @Environment(WorkshopEditing.self) private var editing
    @Environment(\.undoManager) private var undoManager
    let part: PartRecord
    let isEditable: Bool

    var body: some View {
        if let facts = parts.facts(for: part.id) {
            HStack(spacing: PartLineLayout.spacing) {
                PartStateButton(part: part, isEditable: isEditable)
                    .frame(width: PartLineLayout.stateWidth, alignment: .leading)
                InPlaceField(
                    field: facts.name, isEditable: isEditable,
                    identifier: "partName-\(part.id.uuidString)")
                // The description, quantity and day are columns, so they line up from line to
                // line.
                Text(part.description ?? "")
                    .font(.system(size: PartLineLayout.detailSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: PartLineLayout.descriptionWidth, alignment: .leading)
                Text(part.quantity > 1 ? "× \(part.quantity)" : "")
                    .font(.system(size: PartLineLayout.detailSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: PartLineLayout.quantityWidth, alignment: .trailing)
                    .accessibilityLabel("Quantity \(part.quantity)")
                Text(PartWording.shortDay(of: part) ?? "")
                    .font(.system(size: PartLineLayout.detailSize))
                    .foregroundStyle(.secondary)
                    .frame(width: PartLineLayout.dayWidth, alignment: .trailing)
                PartOpenButton(part: part)
            }
            .frame(minHeight: PartLineLayout.rowHeight)
            .zIndex(facts.name.isEditing ? 1 : 0)
            .contextMenu { PartMenuButtons(part: part, isEditable: isEditable) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("partLine-\(part.id.uuidString)")
        }
    }
}

// The state at the start of a part's line. A click moves the part on, such as Needed to
// Ordered, and records the day. A fitted part stays fitted.
private struct PartStateButton: View {
    @Environment(PartState.self) private var parts
    @Environment(\.undoManager) private var undoManager
    let part: PartRecord
    let isEditable: Bool

    var body: some View {
        Button(action: advance) {
            PartStagePill(stage: part.stage).contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEditable)
        .help(PartWording.advanceTitle(of: part.stage) ?? part.stage.rawValue)
        .accessibilityLabel("State of \(part.name)")
        .accessibilityValue(part.stage.rawValue)
        .accessibilityHint(PartWording.advanceTitle(of: part.stage) ?? "")
        .accessibilityIdentifier("partState-\(part.id.uuidString)")
    }

    private func advance() { parts.advanceCommand(part.id, undoManager: undoManager) }
}

// The arrow at the end of a part's line. It opens the part's page.
private struct PartOpenButton: View {
    @Environment(PartState.self) private var parts
    @Environment(WorkshopEditing.self) private var editing
    let part: PartRecord

    var body: some View {
        Button(action: open) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: InPlaceLayout.openWidth, height: PartLineLayout.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(part.name)")
        .accessibilityLabel("Open \(part.name)")
        .accessibilityIdentifier("openPart-\(part.id.uuidString)")
    }

    private func open() {
        let id = part.id
        editing.requestNavigation { parts.select(id) }
    }
}

// A part's commands for its right-click menu: its state, its page and its removal.
struct PartMenuButtons: View {
    @Environment(PartState.self) private var parts
    @Environment(WorkshopEditing.self) private var editing
    @Environment(\.undoManager) private var undoManager
    let part: PartRecord
    let isEditable: Bool
    var opens = true

    var body: some View {
        Picker("State", selection: stage) {
            ForEach(PartStage.allCases) { stage in
                Text(stage.rawValue).tag(stage)
            }
        }
        .pickerStyle(.inline)
        .disabled(!isEditable)
        Divider()
        if opens {
            Button("Open Part", action: open)
        }
        Button(PartState.removeActionName, role: .destructive, action: remove)
            .disabled(!isEditable)
    }

    private var stage: Binding<PartStage> { Binding(get: currentStage, set: choose) }
    private func currentStage() -> PartStage { part.stage }
    private func choose(_ stage: PartStage) {
        parts.setStageCommand(stage, of: part.id, undoManager: undoManager)
    }

    private func open() {
        let id = part.id
        editing.requestNavigation { parts.select(id) }
    }

    private func remove() { parts.removeCommand(part.id, undoManager: undoManager) }
}

// The line after a job's last part, where you type the next one. While you type, the spares in
// hand whose name matches show under it.
private struct PartEntryLine: View {
    @Environment(PartState.self) private var parts
    @Environment(\.undoManager) private var undoManager
    let entry: PartEntry

    var body: some View {
        HStack(spacing: PartLineLayout.spacing) {
            Image(systemName: "plus")
                .font(.system(size: ChecklistLayout.plusSize, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, PartLineLayout.plusLeading)
                .frame(width: PartLineLayout.stateWidth, alignment: .leading)
                .accessibilityHidden(true)
            PartEntryTextView(
                entry: entry, text: entry.text, isEditable: true,
                identifier: "addPart-\(entry.jobID.uuidString)", submit: submit
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) { prompt }
            .padding(.horizontal, InPlaceLayout.inset)
            .frame(height: PartLineLayout.rowHeight)
            .background(fill, in: RoundedRectangle(cornerRadius: InPlaceLayout.cornerRadius))
            .background(alignment: .topLeading) { spares }
        }
        .zIndex(entry.isEditing ? 1 : 0)
    }

    @ViewBuilder private var prompt: some View {
        if entry.text.isEmpty, !entry.isEditing {
            Text(PartEntryWording.prompt)
                .font(.system(size: InPlaceLayout.textSize))
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var fill: Color {
        entry.isEditing ? Color.accentColor.opacity(ChecklistLayout.editingOpacity) : .clear
    }

    @ViewBuilder private var spares: some View {
        let found = entry.spares
        if !found.isEmpty {
            SpareList(entry: entry, spares: found, use: use)
                .offset(y: PartLineLayout.rowHeight + InPlaceLayout.listGap)
        }
    }

    // Adds the typed part, or puts the highlighted spare on the job. The line empties at once,
    // so the next part can follow while this one saves. A part that did not save comes back.
    private func submit() {
        let text = entry.text
        let spare = entry.highlightedID
        entry.clear()
        Task {
            let succeeded: Bool
            if let spare {
                succeeded = await parts.useSpare(spare, on: entry.jobID, undoManager: undoManager)
            } else {
                succeeded =
                    await parts.add(named: text, to: entry.jobID, undoManager: undoManager) != nil
            }
            if !succeeded, entry.text.isEmpty { entry.change(to: text) }
        }
    }

    private func use(_ spare: PartRecord) {
        entry.clear()
        let jobID = entry.jobID
        Task { await parts.useSpare(spare.id, on: jobID, undoManager: undoManager) }
    }
}

// The spares in hand whose name has what you typed, under the line you type in. The Down arrow
// highlights one, and Return or a click puts it on the job.
private struct SpareList: View {
    let entry: PartEntry
    let spares: [PartRecord]
    let use: (PartRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Spares in the drawer")
                .font(.system(size: InPlaceLayout.labelSize, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, InPlaceLayout.inset)
                .frame(height: PartLineLayout.listHeadingHeight, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            ForEach(spares) { spare in
                SpareRow(spare: spare, isHighlighted: spare.id == entry.highlightedID, use: use)
            }
            Text("↓ then Return uses a spare · Return alone adds a new part")
                .font(.system(size: InPlaceLayout.hintSize))
                .foregroundStyle(.secondary)
                .padding(.horizontal, InPlaceLayout.inset)
                .padding(.top, PartLineLayout.listHintTop)
                .padding(.bottom, PartLineLayout.listHintBottom)
        }
        .padding(InPlaceLayout.listPadding)
        .frame(width: PartLineLayout.listWidth, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: InPlaceLayout.listRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: InPlaceLayout.listRadius)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 8)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spares in the drawer")
    }
}

private struct SpareRow: View {
    let spare: PartRecord
    let isHighlighted: Bool
    let use: (PartRecord) -> Void

    var body: some View {
        Button(action: take) {
            HStack(spacing: PartLineLayout.iconSpacing) {
                Image(systemName: PartListLayout.spareSymbol)
                    .font(.system(size: InPlaceLayout.rowDetailSize))
                    .foregroundStyle(isHighlighted ? Color.white : Color.secondary)
                    .accessibilityHidden(true)
                Text(spare.name)
                    .font(.system(size: InPlaceLayout.rowTextSize))
                    .foregroundStyle(isHighlighted ? Color.white : Color.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: InPlaceLayout.rowDetailSize))
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, InPlaceLayout.inset)
            .frame(height: InPlaceLayout.rowHeight)
            .background(
                isHighlighted ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: InPlaceLayout.rowRadius)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use spare \(spare.name), \(detail)")
        .accessibilityIdentifier("useSpare-\(spare.id.uuidString)")
    }

    // The spare's description and quantity, such as "Cal. 2824 · × 2", or that it is in hand.
    private var detail: String {
        var parts = [spare.description].compactMap { $0 }
        if spare.quantity > 1 { parts.append("× \(spare.quantity)") }
        return parts.isEmpty ? "In hand" : parts.joined(separator: " · ")
    }

    private func take() { use(spare) }
}

enum PartLineLayout {
    static let rowHeight: CGFloat = 32
    static let spacing: CGFloat = 8
    // The state column is as wide as the widest pill, so the names line up.
    static let stateWidth: CGFloat = 84
    static let plusLeading: CGFloat = 9
    static let detailSize: CGFloat = 12
    static let descriptionWidth: CGFloat = 220
    static let quantityWidth: CGFloat = 32
    static let dayWidth: CGFloat = 56
    static let messageTop: CGFloat = 8
    static let iconSpacing: CGFloat = 8
    static let listWidth: CGFloat = 440
    static let listHeadingHeight: CGFloat = 22
    static let listHintTop: CGFloat = 4
    static let listHintBottom: CGFloat = 2
}
