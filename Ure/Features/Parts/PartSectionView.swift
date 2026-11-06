import SwiftUI

// The job's parts under the Parts heading, laid out as on the "2 Job" artboard. Each part is one
// line: its state, its name written in place with its quantity, and under the name its
// description and the day of its state. A click on the state moves the part on and records the
// day. The line after the last part adds the next one as you type, as on the parts card of the
// "7 Typing" artboard, and offers the spares in hand whose name matches. Parts and checklist
// steps are independent.
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
            Divider()
            ForEach(lines) { part in
                PartLine(part: part, isEditable: isEditable)
                Divider()
            }
            if isEditable {
                let entry = state.entry(for: jobID)
                PartEntryLine(entry: entry)
                if entry.isTyping {
                    PartKeyHints().padding(.top, PartLineLayout.hintsTop)
                }
                PartWaitingNames(entry: entry)
            } else if lines.isEmpty {
                Text("No parts")
                    .foregroundStyle(.secondary)
                    .frame(height: PartLineLayout.entryHeight)
            }
            if let error = state.refusal {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: NotesLayout.failureSize))
                    .foregroundStyle(.red)
                    .padding(.top, PartLineLayout.messageTop)
            }
        }
    }
}

// One part: its state, which a click moves on, its name written in place with its quantity, the
// line under it, and an arrow that opens its page. A fitted part reads quieter.
private struct PartLine: View {
    @Environment(PartState.self) private var parts
    let part: PartRecord
    let isEditable: Bool

    var body: some View {
        if let facts = parts.facts(for: part.id) {
            HStack(spacing: PartLineLayout.spacing) {
                PartStateButton(part: part, isEditable: isEditable)
                VStack(alignment: .leading, spacing: PartLineLayout.textSpacing) {
                    HStack(spacing: PartLineLayout.quantitySpacing) {
                        InPlaceField(
                            field: facts.name, isEditable: isEditable,
                            identifier: "partName-\(part.id.uuidString)",
                            isQuiet: part.stage == .fitted, showsHint: false
                        )
                        // At rest the name is as wide as its text, so the quantity follows it.
                        .frame(
                            maxWidth: facts.name.isEditing ? .infinity : width(of: facts.name.text),
                            alignment: .leading)
                        if part.quantity > 1 {
                            Text("× \(part.quantity)")
                                .font(.system(size: InPlaceLayout.textSize))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .accessibilityLabel("Quantity \(part.quantity)")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, -InPlaceLayout.inset)
                    if let detail = PartWording.detail(of: part) {
                        Text(detail)
                            .font(.system(size: PartLineLayout.detailSize))
                            .foregroundStyle(part.stage == .fitted ? .tertiary : .secondary)
                            .lineLimit(1)
                    }
                }
                PartOpenButton(part: part)
            }
            .frame(height: PartLineLayout.rowHeight)
            .zIndex(facts.name.isEditing ? 1 : 0)
            .contextMenu { PartMenuButtons(part: part, isEditable: isEditable) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("partLine-\(part.id.uuidString)")
        }
    }
}

extension PartLine {
    // The width of a name at rest, inside the field's insets.
    fileprivate func width(of name: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: InPlaceLayout.textSize)
        let text = (name as NSString).size(withAttributes: [.font: font]).width
        return ceil(text) + 2 * InPlaceLayout.inset + PartLineLayout.nameSlack
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

// The line after a job's last part, where you type the next one, as on the parts card of the
// "7 Typing" artboard. At rest it shows a plus and "Add a part or use a spare". While you type,
// it shows the Needed pill the part starts with, the name with the typing ring, and a
// description that Tab reaches. The spares in hand whose name matches show under it.
private struct PartEntryLine: View {
    @Environment(PartState.self) private var parts
    @Environment(\.undoManager) private var undoManager
    let entry: PartEntry

    var body: some View {
        HStack(spacing: PartLineLayout.spacing) {
            Group {
                if entry.isTyping {
                    PartStagePill(stage: .needed)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: ChecklistLayout.plusSize, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: PartPillLayout.width)
            .accessibilityHidden(true)
            PartEntryBox(isTyping: entry.isEditing) {
                PartEntryTextView(
                    entry: entry, role: .name, isEditable: true,
                    identifier: "addPart-\(entry.jobID.uuidString)", submit: submit
                )
                .overlay(alignment: .leading) {
                    if entry.text.isEmpty, !entry.isEditing {
                        PartEntryPrompt(text: PartEntryWording.prompt)
                    }
                }
            }
            .background(alignment: .topLeading) { spares }
            if entry.isTyping {
                PartEntryBox(isTyping: entry.isEditingDescription) {
                    PartEntryTextView(
                        entry: entry, role: .description, isEditable: true,
                        identifier: "\(PartEntryWording.descriptionID)\(entry.jobID.uuidString)",
                        submit: submit
                    )
                    .overlay(alignment: .leading) {
                        if entry.description.isEmpty, !entry.isEditingDescription {
                            PartEntryPrompt(text: PartEntryWording.descriptionPrompt)
                        }
                    }
                }
                .frame(width: PartLineLayout.descriptionWidth)
            }
        }
        .frame(height: PartLineLayout.entryHeight)
        .zIndex(entry.isTyping ? 1 : 0)
    }

    @ViewBuilder private var spares: some View {
        let found = entry.spares
        if !found.isEmpty {
            SpareList(entry: entry, spares: found, use: use)
                .offset(x: -InPlaceLayout.inset, y: InPlaceLayout.boxHeight + InPlaceLayout.listGap)
        }
    }

    private func submit() { parts.submitCommand(entry, undoManager: undoManager) }

    private func use(_ spare: PartRecord) {
        entry.clear()
        let jobID = entry.jobID
        parts.useSpare(spare.id, on: jobID, undoManager: undoManager)
    }
}

// The box around one field of the add line. While you type in it, it has the field's typing
// ring, as on "7 Typing".
private struct PartEntryBox<Content: View>: View {
    let isTyping: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, InPlaceLayout.inset)
            .frame(height: InPlaceLayout.boxHeight)
            .background(
                isTyping ? Color(nsColor: .textBackgroundColor) : .clear,
                in: RoundedRectangle(cornerRadius: InPlaceLayout.cornerRadius)
            )
            .background {
                if isTyping {
                    RoundedRectangle(
                        cornerRadius: InPlaceLayout.cornerRadius + InPlaceLayout.ringSpread
                    )
                    .fill(Color.accentColor.opacity(InPlaceLayout.ringOpacity))
                    .padding(-InPlaceLayout.ringSpread)
                }
            }
            .overlay {
                if isTyping {
                    RoundedRectangle(cornerRadius: InPlaceLayout.cornerRadius)
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                }
            }
            .padding(.leading, -InPlaceLayout.inset)
    }
}

private struct PartEntryPrompt: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: InPlaceLayout.textSize))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// How typing a part works, under the add line while you type, as on "7 Typing".
private struct PartKeyHints: View {
    var body: some View {
        HStack(spacing: ChecklistLayout.hintSpacing) {
            PartKeyHint(key: "Tab", meaning: "Description")
            PartKeyHint(key: "Return", meaning: "Add and start the next")
            PartKeyHint(key: "↓", meaning: "Use a spare")
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PartKeyHint: View {
    let key: String
    let meaning: String

    var body: some View {
        HStack(spacing: ChecklistLayout.keySpacing) {
            Text(key)
                .font(.system(size: ChecklistLayout.keySize, weight: .medium))
                .padding(.horizontal, ChecklistLayout.keyInset)
                .frame(height: ChecklistLayout.keyHeight)
                .background(Color(nsColor: .quaternarySystemFill))
                .overlay(alignment: .bottom) {
                    Color(nsColor: .separatorColor).frame(height: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: ChecklistLayout.keyRadius))
            Text(meaning)
                .font(.system(size: ChecklistLayout.meaningSize))
                .foregroundStyle(.secondary)
        }
    }
}

// The parts typed on the line that have not saved, while a failed save holds them. The failure
// bar has Try Again and Discard.
private struct PartWaitingNames: View {
    @Environment(WorkshopEditing.self) private var editing
    let entry: PartEntry

    var body: some View {
        if editing.failure != nil, !entry.waiting.isEmpty {
            Label {
                Text("Not saved yet: \(entry.waiting.map(\.name).joined(separator: ", "))")
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
            }
            .font(.system(size: NotesLayout.failureSize))
            .foregroundStyle(.red)
            .padding(.top, PartLineLayout.messageTop)
        }
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

    // The first line of the spare's description and its quantity, such as "Cal. 2824 · × 2",
    // or that it is in hand.
    private var detail: String {
        var parts = [PartWording.firstLine(of: spare.description)].compactMap { $0 }
        if spare.quantity > 1 { parts.append("× \(spare.quantity)") }
        return parts.isEmpty ? "In hand" : parts.joined(separator: " · ")
    }

    private func take() { use(spare) }
}

// Values from the "2 Job" artboard and the parts card of "7 Typing" on the Paper page "Rework ·
// Simple".
enum PartLineLayout {
    static let rowHeight: CGFloat = 56
    static let entryHeight: CGFloat = 48
    static let spacing: CGFloat = 16
    // The name's box is 32 pt high around a 20 pt line, so the line under it sits 2 pt below
    // the text, as on the artboard.
    static let textSpacing: CGFloat = -4
    // The quantity follows the name about one space after it, past the field's inset.
    static let quantitySpacing: CGFloat = -4
    // A little room after a name at rest, so its last letter never clips.
    static let nameSlack: CGFloat = 2
    static let detailSize: CGFloat = 12
    static let descriptionWidth: CGFloat = 180
    static let messageTop: CGFloat = 8
    static let hintsTop: CGFloat = 12
    static let iconSpacing: CGFloat = 8
    static let listWidth: CGFloat = 440
    static let listHeadingHeight: CGFloat = 22
}
