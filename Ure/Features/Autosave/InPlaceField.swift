import SwiftUI

// A fact you write on in place, with a small label above it. The states follow the "7 Typing"
// artboard. At rest it reads as plain text, and an empty field shows a quiet prompt. Pointing at
// it shows a soft fill. While you type, the label turns to the accent colour and an accent ring
// shows where you are. Matches from the library show under the field. When focus leaves a text
// the field does not take, the label and the outline turn red and a line says what to enter.
struct FactRow: View {
    let field: FactField
    let isEditable: Bool
    let identifier: String
    var requestsFocus = false
    var didFocus: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: InPlaceLayout.labelSpacing) {
            FactLabel(text: field.label, tone: FactTone(field))
            InPlaceField(
                field: field, isEditable: isEditable, identifier: identifier,
                requestsFocus: requestsFocus, didFocus: didFocus)
        }
        .zIndex(field.isEditing ? 1 : 0)
    }
}

struct InPlaceField: View {
    let field: FactField
    let isEditable: Bool
    let identifier: String
    var style = InPlaceStyle.body
    var requestsFocus = false
    var didFocus: () -> Void = {}
    var isQuiet = false
    // Whether the line under the field says how typing works. A field on a busy line, such as a
    // part's name on its job, leaves it out and still says what to correct.
    var showsHint = true
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InPlaceTextView(
                field: field, text: field.text, suggestion: field.suggestion, style: style,
                isEditable: isEditable, identifier: identifier, requestsFocus: requestsFocus,
                didFocus: didFocus, isQuiet: isQuiet
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) { prompt }
            .padding(.horizontal, InPlaceLayout.inset)
            .frame(height: style.boxHeight)
            .background(fill, in: RoundedRectangle(cornerRadius: InPlaceLayout.cornerRadius))
            .background(ring)
            .overlay(outline)
            .onHover(perform: hover)
            // Behind the field, so the list's shadow never greys the field.
            .background(alignment: .topLeading) { matches }
            FactMessage(field: field, showsHint: showsHint)
        }
        .zIndex(field.isEditing ? 1 : 0)
    }

    private var tone: FactTone { FactTone(field) }

    // The quiet prompt of an empty field at rest, in the same grey as the notes prompt.
    @ViewBuilder private var prompt: some View {
        if field.text.isEmpty, !field.isEditing {
            Text(field.prompt)
                .font(Font(style.font))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var fill: Color {
        if tone != .rest { return Color(nsColor: .textBackgroundColor) }
        if isEditable, isHovering { return Color(nsColor: .quaternarySystemFill) }
        return .clear
    }

    @ViewBuilder private var ring: some View {
        if tone == .editing {
            RoundedRectangle(cornerRadius: InPlaceLayout.cornerRadius + InPlaceLayout.ringSpread)
                .fill(Color.accentColor.opacity(InPlaceLayout.ringOpacity))
                .padding(-InPlaceLayout.ringSpread)
        }
    }

    @ViewBuilder private var outline: some View {
        switch tone {
        case .editing:
            RoundedRectangle(cornerRadius: InPlaceLayout.cornerRadius).strokeBorder(
                Color.accentColor, lineWidth: 1)
        case .invalid:
            RoundedRectangle(cornerRadius: InPlaceLayout.cornerRadius).strokeBorder(
                Color.red, lineWidth: 1)
        case .rest: EmptyView()
        }
    }

    @ViewBuilder private var matches: some View {
        if !field.matches.isEmpty {
            FactMatchList(field: field)
                .offset(y: style.boxHeight + InPlaceLayout.listGap)
        }
    }

    private func hover(_ isInside: Bool) { isHovering = isInside }
}

// How a fact looks: at rest, typing, or not valid yet.
enum FactTone: Equatable {
    case rest
    case editing
    case invalid

    init(_ field: FactField) {
        if field.isEditing {
            self = .editing
        } else if field.problem != nil {
            self = .invalid
        } else {
            self = .rest
        }
    }
}

struct FactLabel: View {
    let text: String
    let tone: FactTone

    var body: some View {
        Text(text)
            .font(.system(size: InPlaceLayout.labelSize, weight: .medium))
            .foregroundStyle(color)
            .padding(.leading, InPlaceLayout.inset)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch tone {
        case .rest: .secondary
        case .editing: .accentColor
        case .invalid: .red
        }
    }
}

// The line under a fact: what to enter, or how typing works.
struct FactMessage: View {
    let field: FactField
    var showsHint = true

    var body: some View {
        if let problem = field.problem {
            FactProblem(message: problem)
        } else if showsHint, field.isEditing, field.matches.isEmpty {
            Text("Saved as you type · Esc undoes this field")
                .font(.system(size: InPlaceLayout.hintSize))
                .foregroundStyle(.secondary)
                .padding(.horizontal, InPlaceLayout.inset)
                .padding(.top, InPlaceLayout.hintTop)
        }
    }
}

private struct FactProblem: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
        }
        .font(.system(size: InPlaceLayout.messageSize))
        .foregroundStyle(.red)
        .padding(.horizontal, InPlaceLayout.inset)
        .padding(.top, InPlaceLayout.messageTop)
    }
}

// The library's values that start with what you typed, under the field. The first is the one
// Tab or Return takes, and a click takes any of them.
private struct FactMatchList: View {
    let field: FactField

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(field.matches.enumerated()), id: \.element.text) { index, match in
                FactMatchRow(field: field, match: match, isFirst: index == 0)
            }
        }
        .padding(InPlaceLayout.listPadding)
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
    }
}

private struct FactMatchRow: View {
    @Environment(\.undoManager) private var undoManager
    let field: FactField
    let match: FactSuggestion
    let isFirst: Bool

    var body: some View {
        Button(action: take) {
            HStack {
                Text(match.text)
                    .font(.system(size: InPlaceLayout.rowTextSize))
                    .foregroundStyle(isFirst ? Color.white : Color.primary)
                Spacer(minLength: 8)
                if let detail = match.detail {
                    Text(detail)
                        .font(.system(size: InPlaceLayout.rowDetailSize))
                        .foregroundStyle(isFirst ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .padding(.horizontal, InPlaceLayout.inset)
            .frame(height: InPlaceLayout.rowHeight)
            .background(
                isFirst ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: InPlaceLayout.rowRadius)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let detail = match.detail else { return match.text }
        return "\(match.text), \(detail)"
    }

    private func take() { field.acceptSuggestion(match, undoManager: undoManager) }
}

// One value a fact pop-up offers. The title is what the pop-up shows, such as "Omega 552", and
// the value is what the fact saves.
struct FactPopUpChoice: Identifiable {
    let title: String
    let value: String

    var id: String { value }

    // A choice that saves the text it shows, such as "Automatic".
    init(_ text: String) {
        title = text
        value = text
    }

    init(title: String, value: String) {
        self.title = title
        self.value = value
    }
}

// A fact that is one of a few values, such as a winding or a watch's caliber, as a pop-up
// button with the same label, fill and prompt as a typed fact. A choice saves at once and can be
// undone. A fact that names a record, such as a caliber, can open it from an arrow after its
// name. A fact that can't change reads as plain text, like a typed fact at rest.
struct FactPopUp: View {
    @Environment(\.undoManager) private var undoManager
    let field: FactField
    let choices: [FactPopUpChoice]
    let isEditable: Bool
    let identifier: String
    var open: (() -> Void)? = nil
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: InPlaceLayout.labelSpacing) {
            FactLabel(text: field.label, tone: FactTone(field))
            HStack(spacing: InPlaceLayout.openSpacing) {
                Group {
                    if isEditable {
                        Menu {
                            ForEach(choices) { choice in
                                FactChoice(title: choice.title, value: choice.value, choose: choose)
                            }
                            Divider()
                            FactChoice(title: "None", value: "", choose: choose)
                        } label: {
                            FactPopUpLabel(
                                text: shownText, prompt: field.prompt, showsIndicator: !opensRecord)
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                    } else {
                        FactPopUpLabel(text: shownText, prompt: field.prompt, showsIndicator: false)
                            .accessibilityElement(children: .ignore)
                    }
                }
                .fixedSize()
                .padding(.horizontal, InPlaceLayout.inset)
                .frame(height: InPlaceLayout.boxHeight)
                .background(fill, in: RoundedRectangle(cornerRadius: InPlaceLayout.cornerRadius))
                .onHover(perform: hover)
                .accessibilityLabel(field.label)
                .accessibilityValue(shownText)
                .accessibilityIdentifier(identifier)
                if let open, opensRecord {
                    FactOpenButton(title: shownText, open: open)
                        .padding(.leading, -InPlaceLayout.inset)
                }
            }
            FactMessage(field: field)
        }
    }

    // The title of the chosen value, or the saved text when no choice has it.
    private var shownText: String {
        choices.first { $0.value == field.text }?.title ?? field.text
    }

    private var opensRecord: Bool { open != nil && !field.text.isEmpty }

    private var fill: Color {
        if isEditable, isHovering { return Color(nsColor: .quaternarySystemFill) }
        return .clear
    }

    private func hover(_ isInside: Bool) { isHovering = isInside }
    private func choose(_ value: String) { field.choose(value, undoManager: undoManager) }
}

// The arrow after a fact that names a record. It opens that record, also when the fact is
// read-only.
private struct FactOpenButton: View {
    let title: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: InPlaceLayout.openWidth, height: InPlaceLayout.boxHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(title)")
        .accessibilityLabel("Open \(title)")
    }
}

private struct FactChoice: View {
    let title: String
    let value: String
    let choose: (String) -> Void

    var body: some View {
        Button(title, action: select)
    }

    private func select() { choose(value) }
}

private struct FactPopUpLabel: View {
    let text: String
    let prompt: String
    let showsIndicator: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(text.isEmpty ? prompt : text)
                .font(.system(size: InPlaceLayout.textSize))
                .foregroundStyle(text.isEmpty ? .tertiary : .primary)
            if showsIndicator {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
