import SwiftUI

// The job's checklist, laid out as on the "2 Job" artboard: the heading with how many steps are
// done and a thin progress bar, then the steps and headings, and a row that adds a step. You
// type it like a note, as on the "7 Typing" artboard, and it saves as you type.
struct ChecklistSectionView: View {
    @Environment(ChecklistState.self) private var checklist
    @Environment(WorkshopEditing.self) private var editing
    let jobID: UUID

    var body: some View {
        let editor = checklist.editor(for: jobID)
        VStack(alignment: .leading, spacing: JobSectionLayout.spacing) {
            PageSectionHeading(title: "Checklist", detail: summary(editor))
                .padding(.bottom, JobSectionLayout.headingBottom)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Checklist")
                .accessibilityValue(editor.progress.accessibilitySummary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("checklistProgress")
            ChecklistProgressBar(fraction: editor.progress.fraction)
            content(editor)
        }
    }

    private func summary(_ editor: ChecklistEditor) -> String? {
        guard !checklist.isLoading, checklist.loadError == nil else { return nil }
        return editor.progress.summary
    }

    @ViewBuilder private func content(_ editor: ChecklistEditor) -> some View {
        if checklist.isLoading {
            ProgressView("Loading the checklist…")
        } else if let error = checklist.loadError {
            Label(error, systemImage: "exclamationmark.triangle")
            Button("Retry", action: retry)
        } else {
            ChecklistLines(editor: editor, isEditable: editing.canWrite(.job(jobID)))
        }
    }

    private func retry() { Task { await checklist.observe() } }
}

// A thin bar under the heading that fills as steps are ticked.
private struct ChecklistProgressBar: View {
    let fraction: Double

    var body: some View {
        RoundedRectangle(cornerRadius: ChecklistLayout.barRadius)
            .fill(Color(nsColor: .quaternarySystemFill))
            .frame(height: ChecklistLayout.barHeight)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: ChecklistLayout.barRadius)
                        .fill(Color.accentColor)
                        .frame(width: (geometry.size.width * fraction).rounded())
                }
            }
            .accessibilityHidden(true)
    }
}

// The lines of a checklist, then the row that adds a step while the job can change.
private struct ChecklistLines: View {
    let editor: ChecklistEditor
    let isEditable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                ChecklistLine(
                    editor: editor, line: line, isFirst: line.id == lines.first?.id,
                    isEditable: isEditable)
            }
            if editor.editingID != nil {
                ChecklistKeyHints().padding(.top, ChecklistLayout.hintsTop)
            }
            if let error = editor.saveError {
                ChecklistSaveFailure(message: error, retry: editor.saveNow)
                    .padding(.top, ChecklistLayout.hintsTop)
            }
        }
        .padding(.top, ChecklistLayout.listTop)
    }

    private var lines: [ChecklistLineItem] {
        var lines = editor.steps.map { ChecklistLineItem(id: $0.id, step: $0) }
        if isEditable { lines.append(ChecklistLineItem(id: editor.addID, step: nil)) }
        return lines
    }
}

// A step or a heading, or the row that adds a step when it has no step yet.
private struct ChecklistLineItem: Identifiable {
    let id: UUID
    let step: ChecklistStep?
}

// One line: the tick box and the step's text, or a heading's text in its place. The line you
// type in has a soft accent fill.
private struct ChecklistLine: View {
    let editor: ChecklistEditor
    let line: ChecklistLineItem
    let isFirst: Bool
    let isEditable: Bool

    var body: some View {
        HStack(spacing: ChecklistLayout.boxSpacing) {
            leading.frame(width: ChecklistLayout.boxSize, height: ChecklistLayout.boxSize)
            ChecklistStepTextView(
                editor: editor, id: line.id, text: step?.text ?? "",
                style: isHeading ? .heading : .body, isTicked: step?.isTicked ?? false,
                isEditable: isEditable, label: label, prompt: prompt, focus: focus
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) { shownPrompt }
        }
        .padding(.horizontal, InPlaceLayout.inset)
        .padding(.vertical, isHeading ? ChecklistLayout.headingInset : 0)
        .frame(height: isHeading ? nil : ChecklistLayout.rowHeight)
        .background(fill, in: RoundedRectangle(cornerRadius: InPlaceLayout.cornerRadius))
        .padding(.horizontal, -InPlaceLayout.inset)
        .padding(.top, headingTop)
        .padding(.bottom, isHeading ? ChecklistLayout.headingLineBottom - headingInset : 0)
    }

    private var step: ChecklistStep? { line.step }
    private var isHeading: Bool { step?.isHeading ?? false }
    private var isEditing: Bool { editor.editingID == line.id }
    private var headingInset: CGFloat { isHeading ? ChecklistLayout.headingInset : 0 }

    // A heading sits 14 pt below the line before it, or 4 pt at the top of the list.
    private var headingTop: CGFloat {
        guard isHeading else { return 0 }
        let top = isFirst ? ChecklistLayout.firstHeadingTop : ChecklistLayout.headingTop
        return top - headingInset
    }

    @ViewBuilder private var leading: some View {
        if let step, step.isHeading {
            Color.clear
        } else if let step {
            TickBox(editor: editor, step: step, isEditable: isEditable)
        } else if isEditing {
            TickBoxShape(isTicked: false)
        } else {
            Image(systemName: "plus")
                .font(.system(size: ChecklistLayout.plusSize, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    // VoiceOver reads the text as the field's value, and the label says whether it is ticked.
    private var label: String {
        guard let step else { return "Add a step" }
        if step.isHeading { return "Heading" }
        return step.isTicked ? "Step, ticked" : "Step, not ticked"
    }

    private var prompt: String { step == nil ? "Add a step" : "" }

    @ViewBuilder private var shownPrompt: some View {
        if step == nil, !isEditing {
            Text(prompt)
                .font(.system(size: InPlaceLayout.textSize))
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var focus: StepCursor? {
        guard let request = editor.focusRequest, request.id == line.id else { return nil }
        return request.cursor
    }

    private var fill: Color {
        isEditing ? Color.accentColor.opacity(ChecklistLayout.editingOpacity) : .clear
    }
}

// The 16 pt tick box of a step. Clicking it ticks or unticks the step at once, with Undo.
private struct TickBox: View {
    @Environment(\.undoManager) private var undoManager
    let editor: ChecklistEditor
    let step: ChecklistStep
    let isEditable: Bool

    var body: some View {
        Button(action: toggle) {
            TickBoxShape(isTicked: step.isTicked).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEditable || !editor.canTick(step.id))
        .help(editor.title(of: .tick, for: step.id))
        .contextMenu {
            if isEditable { StepMenuButtons(editor: editor, id: step.id) }
        }
        .accessibilityLabel(step.text.isEmpty ? "Step" : step.text)
        .accessibilityValue(step.isTicked ? "Ticked" : "Not ticked")
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier("checklistTick-\(step.id.uuidString)")
    }

    private func toggle() { editor.toggleTick(step.id, undoManager: undoManager) }
}

// The box itself: filled with the accent colour and a white tick, or an empty outline.
private struct TickBoxShape: View {
    let isTicked: Bool

    var body: some View {
        if isTicked {
            RoundedRectangle(cornerRadius: ChecklistLayout.boxRadius)
                .fill(Color.accentColor)
                .overlay { TickMark().stroke(.white, style: TickMark.style) }
                .frame(width: ChecklistLayout.boxSize, height: ChecklistLayout.boxSize)
        } else {
            RoundedRectangle(cornerRadius: ChecklistLayout.boxRadius)
                .strokeBorder(
                    Color(nsColor: .tertiaryLabelColor), lineWidth: ChecklistLayout.boxLine
                )
                .frame(width: ChecklistLayout.boxSize, height: ChecklistLayout.boxSize)
        }
    }
}

// The tick in a ticked box, drawn as on the artboard in a 10 pt square.
nonisolated private struct TickMark: Shape {
    static let style = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
    // The box the tick is drawn for.
    private static let side: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / Self.side
        let origin = CGPoint(x: rect.midX - 5 * scale, y: rect.midY - 5 * scale)
        var path = Path()
        path.move(to: CGPoint(x: origin.x + 2 * scale, y: origin.y + 5.2 * scale))
        path.addLine(to: CGPoint(x: origin.x + 4 * scale, y: origin.y + 7.2 * scale))
        path.addLine(to: CGPoint(x: origin.x + 8 * scale, y: origin.y + 2.8 * scale))
        return path
    }
}

// The step's commands for its right-click menu, with the same names as the Checklist menu.
struct StepMenuButtons: View {
    @Environment(\.undoManager) private var undoManager
    let editor: ChecklistEditor
    let id: UUID

    var body: some View {
        ForEach(StepCommand.allCases, id: \.self) { command in
            if command == .delete { Divider() }
            StepMenuButton(editor: editor, id: id, command: command, undoManager: undoManager)
        }
    }
}

private struct StepMenuButton: View {
    let editor: ChecklistEditor
    let id: UUID
    let command: StepCommand
    let undoManager: UndoManager?

    var body: some View {
        Button(editor.title(of: command, for: id), action: perform)
            .disabled(!editor.canPerform(command, for: id))
    }

    private func perform() { editor.perform(command, for: id, undoManager: undoManager) }
}

// How typing a checklist works, under it while you type, as on the "7 Typing" artboard.
private struct ChecklistKeyHints: View {
    var body: some View {
        HStack(spacing: ChecklistLayout.hintSpacing) {
            ChecklistKeyHint(key: "Return", meaning: "Next step")
            ChecklistKeyHint(key: "⇧⌘U", meaning: "Tick")
            ChecklistKeyHint(key: "⌃⌘ ↑↓", meaning: "Move")
            ChecklistKeyHint(key: "#", meaning: "Start a heading")
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ChecklistKeyHint: View {
    let key: String
    let meaning: String

    var body: some View {
        HStack(spacing: ChecklistLayout.keySpacing) {
            Text(key)
                .font(.system(size: ChecklistLayout.keySize, weight: .medium))
                .padding(.horizontal, ChecklistLayout.keyInset)
                .frame(height: ChecklistLayout.keyHeight)
                .background(Color(nsColor: .quaternarySystemFill))
                // A key cap's lower edge, as on the artboard.
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

private struct ChecklistSaveFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label {
                Text("The checklist did not save. Your steps are still here. \(message)")
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
            }
            .font(.system(size: NotesLayout.failureSize))
            .foregroundStyle(.red)
            Button("Try Again", action: retry)
                .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
    }
}

// Values from the Checklist on the "2 Job" artboard and the "Steps and parts" card on the
// "7 Typing" artboard, on the Paper page "Rework · Simple".
enum ChecklistLayout {
    static let barHeight: CGFloat = 2
    static let barRadius: CGFloat = 2
    static let listTop: CGFloat = 8
    static let rowHeight: CGFloat = 32
    static let boxSize: CGFloat = 16
    static let boxRadius: CGFloat = 5
    static let boxLine: CGFloat = 1.5
    static let boxSpacing: CGFloat = 12
    static let plusSize: CGFloat = 12
    static let headingSize: CGFloat = 12
    static let headingLineHeight: CGFloat = 15
    static let headingTop: CGFloat = 14
    static let firstHeadingTop: CGFloat = 4
    static let headingLineBottom: CGFloat = 6
    // The fill of a heading you type in reaches 2 pt above and below its text.
    static let headingInset: CGFloat = 2
    static let editingOpacity: Double = 0.07
    static let hintsTop: CGFloat = 12
    static let hintSpacing: CGFloat = 16
    static let keySpacing: CGFloat = 6
    static let keySize: CGFloat = 11
    static let keyInset: CGFloat = 6
    static let keyHeight: CGFloat = 20
    static let keyRadius: CGFloat = 5
    static let meaningSize: CGFloat = 12
}
