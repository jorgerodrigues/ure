import SwiftUI

// A fact you write on in place, with its label. At rest it reads as plain text, and an empty
// field shows its prompt. Hovering shows that you can write on it, and focus shows where you
// type. While you type, a suggestion shows in grey. When focus leaves a text the field does
// not take, the field is not valid yet: the text stays, and the message under it says what to
// write and which value the record keeps.
struct FactRow: View {
    let field: FactField
    let isEditable: Bool
    let identifier: String
    var requestsFocus = false
    var didFocus: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: InPlaceLayout.columnSpacing) {
            Text(field.label)
                .foregroundStyle(.secondary)
                .frame(
                    width: InPlaceLayout.labelWidth, height: InPlaceLayout.lineHeight,
                    alignment: .leading
                )
                .accessibilityHidden(true)
            InPlaceField(
                field: field, isEditable: isEditable, identifier: identifier,
                requestsFocus: requestsFocus, didFocus: didFocus)
        }
    }
}

struct InPlaceField: View {
    let field: FactField
    let isEditable: Bool
    let identifier: String
    var requestsFocus = false
    var didFocus: () -> Void = {}
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: InPlaceLayout.messageSpacing) {
            InPlaceTextView(
                field: field, text: field.text, suggestion: field.suggestion,
                isEditable: isEditable, identifier: identifier, requestsFocus: requestsFocus,
                didFocus: didFocus
            )
            .frame(maxWidth: .infinity, minHeight: InPlaceLayout.lineHeight, alignment: .leading)
            .padding(.horizontal, InPlaceLayout.inset)
            .background(fill, in: shape)
            .overlay(outline)
            .onHover(perform: hover)
            FactMessage(field: field)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: InPlaceLayout.cornerRadius)
    }

    private var fill: Color {
        if field.isEditing { return Color(nsColor: .textBackgroundColor) }
        if isEditable, isHovering { return Color(nsColor: .quaternarySystemFill) }
        return .clear
    }

    @ViewBuilder private var outline: some View {
        if field.isEditing {
            shape.strokeBorder(
                Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: InPlaceLayout.focusWidth)
        } else if field.problem != nil {
            shape.strokeBorder(Color.red, lineWidth: 1)
        }
    }

    private func hover(_ isInside: Bool) { isHovering = isInside }
}

// The line under a fact: why it is not valid yet, that it did not save, or how typing works.
private struct FactMessage: View {
    let field: FactField

    var body: some View {
        if let error = field.saveError {
            FactSaveFailure(message: error, retry: field.saveNow)
        } else if let problem = field.problem {
            Label {
                Text("Not valid yet. \(problem)")
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
            }
            .font(.system(size: InPlaceLayout.messageSize))
            .foregroundStyle(.red)
        } else if let suggestion = field.suggestion, field.isEditing {
            FactHint(text: "Tab or Return takes “\(suggestion)”")
        } else if field.isEditing {
            FactHint(text: "Saved as you type · Esc undoes this field")
        }
    }
}

private struct FactHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: InPlaceLayout.hintSize))
            .foregroundStyle(.secondary)
    }
}

private struct FactSaveFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label {
                Text("This did not save. Your text is still here. \(message)")
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
            }
            .font(.system(size: InPlaceLayout.messageSize))
            .foregroundStyle(.red)
            Button("Try Again", action: retry)
                .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
    }
}
