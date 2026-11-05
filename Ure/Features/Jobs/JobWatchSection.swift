import AppKit
import SwiftUI

// The facts of a job that has no watch yet, laid out as the "6 New job" artboard: the watch
// picker, and the caliber, owner and contact that come from the watch once you pick it.
struct JobWatchFacts: View {
    let job: JobRecord
    let isEditable: Bool
    @State private var picker = WatchPickerModel()

    var body: some View {
        VStack(alignment: .leading, spacing: JobWatchLayout.rowSpacing) {
            HStack(alignment: .top, spacing: PageLayout.factColumnSpacing) {
                WatchPickerField(picker: picker, isEditable: isEditable)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .zIndex(1)
                FromWatchFact(label: "Caliber", height: InPlaceLayout.boxHeight)
            }
            .zIndex(1)
            HStack(alignment: .top, spacing: PageLayout.factColumnSpacing) {
                FromWatchFact(label: "Owner", height: JobWatchLayout.lowerHeight)
                FromWatchFact(label: "Contact", height: JobWatchLayout.lowerHeight)
            }
        }
        .padding(.top, JobWatchLayout.topPadding)
        .overlay(alignment: .top) { Divider() }
    }
}

// A fact the job takes from its watch. Until the job has a watch, it says so.
private struct FromWatchFact: View {
    let label: String
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: InPlaceLayout.labelSpacing) {
            Text(label)
                .font(.system(size: InPlaceLayout.labelSize, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Comes from the watch")
                .font(.system(size: InPlaceLayout.textSize))
                .foregroundStyle(.tertiary)
                .frame(height: height, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// The Watch fact: a search field with the matching watches under it. Return takes the
// highlighted watch, and the arrows move the highlight.
private struct WatchPickerField: View {
    @Environment(JobState.self) private var jobs
    @Environment(WatchState.self) private var watches
    @Environment(CaliberState.self) private var calibers
    @Environment(WorkshopEditing.self) private var editing
    @Environment(\.undoManager) private var undoManager
    let picker: WatchPickerModel
    let isEditable: Bool
    @State private var isHovering = false

    var body: some View {
        let items = picker.items(
            watches: watches.watches, calibers: calibers.calibers, jobs: jobs.jobs)
        VStack(alignment: .leading, spacing: InPlaceLayout.labelSpacing) {
            Text("Watch")
                .font(.system(size: InPlaceLayout.labelSize, weight: .medium))
                .foregroundStyle(picker.isEditing ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            HStack(spacing: JobWatchLayout.iconSpacing) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: JobWatchLayout.iconSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                WatchPickerTextView(
                    picker: picker, isEditable: isEditable, count: items.count,
                    pick: { pickHighlighted(in: items) }
                )
                .overlay(alignment: .leading) { prompt }
            }
            .padding(.horizontal, InPlaceLayout.inset)
            .frame(height: InPlaceLayout.boxHeight)
            .background(fill, in: RoundedRectangle(cornerRadius: InPlaceLayout.cornerRadius))
            .background(ring)
            .overlay(outline)
            .padding(.leading, -InPlaceLayout.inset)
            .onHover(perform: hover)
            .background(alignment: .topLeading) {
                if picker.isEditing, !items.isEmpty {
                    WatchPickerList(
                        items: items, highlighted: picker.highlightedItem(in: items),
                        pick: pick
                    )
                    .offset(
                        x: JobWatchLayout.listInset,
                        y: InPlaceLayout.boxHeight + JobWatchLayout.listGap)
                }
            }
            if let error = jobs.saveError, picker.isEditing {
                Text(error)
                    .font(.system(size: InPlaceLayout.messageSize))
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var prompt: some View {
        if picker.query.isEmpty, !picker.isEditing {
            Text(isEditable ? "Find a watch by name, brand or caliber" : "No watch yet")
                .font(.system(size: InPlaceLayout.textSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var fill: Color {
        if picker.isEditing { return Color(nsColor: .textBackgroundColor) }
        if isEditable, isHovering { return Color(nsColor: .quaternarySystemFill) }
        return .clear
    }

    @ViewBuilder private var ring: some View {
        if picker.isEditing {
            RoundedRectangle(cornerRadius: InPlaceLayout.cornerRadius + InPlaceLayout.ringSpread)
                .fill(Color.accentColor.opacity(InPlaceLayout.ringOpacity))
                .padding(-InPlaceLayout.ringSpread)
        }
    }

    @ViewBuilder private var outline: some View {
        if picker.isEditing {
            RoundedRectangle(cornerRadius: InPlaceLayout.cornerRadius)
                .strokeBorder(Color.accentColor, lineWidth: 1)
        }
    }

    private func hover(_ isInside: Bool) { isHovering = isInside }

    private func pickHighlighted(in items: [WatchPickerItem]) {
        guard let item = picker.highlightedItem(in: items) else { return }
        pick(item)
    }

    private func pick(_ item: WatchPickerItem) {
        let picker = picker
        let jobs = jobs
        let watches = watches
        let undoManager = undoManager
        editing.requestNavigation {
            Task {
                await picker.pick(item, jobs: jobs, watches: watches, undoManager: undoManager)
            }
        }
    }
}

// The watches that match, as on "6 New job". The highlighted row is the one Return takes. A
// watch with an open job reads quieter. The last row makes a new watch with the typed name.
private struct WatchPickerList: View {
    let items: [WatchPickerItem]
    let highlighted: WatchPickerItem?
    let pick: (WatchPickerItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                switch item {
                case .watch(let choice):
                    WatchPickerRow(
                        choice: choice, isHighlighted: item == highlighted, pick: { pick(item) })
                case .newWatch(let name):
                    if items.count > 1 {
                        Divider()
                            .padding(.horizontal, JobWatchLayout.rowPadding)
                            .padding(.vertical, JobWatchLayout.separatorGap)
                    }
                    NewWatchRow(
                        name: name, isHighlighted: item == highlighted, pick: { pick(item) })
                }
            }
        }
        .padding(JobWatchLayout.listPadding)
        .frame(width: JobWatchLayout.listWidth, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: JobWatchLayout.listRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: JobWatchLayout.listRadius)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.14), radius: 16, y: 12)
        .shadow(color: .black.opacity(0.06), radius: 3, y: 2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Watches")
        .accessibilityIdentifier("jobWatchPickerList")
    }
}

private struct WatchPickerRow: View {
    let choice: WatchChoice
    let isHighlighted: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: UreLayout.rowSpacing) {
                PhotoThumbnailView(photoID: choice.watch.coverPhotoID)
                    .frame(
                        width: JobWatchLayout.thumbnailSize, height: JobWatchLayout.thumbnailSize)
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.watch.name)
                        .font(.system(size: JobWatchLayout.nameSize, weight: .semibold))
                        .foregroundStyle(nameColor)
                        .lineLimit(1)
                    if !choice.detail.isEmpty {
                        Text(choice.detail)
                            .font(.system(size: JobWatchLayout.detailSize))
                            .foregroundStyle(detailColor)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isHighlighted {
                    Text("Return")
                        .font(.system(size: JobWatchLayout.keySize))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, JobWatchLayout.rowPadding)
            .frame(height: JobWatchLayout.rowHeight)
            .background(
                isHighlighted ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: JobWatchLayout.rowRadius)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    private var nameColor: Color {
        if isHighlighted { return .white }
        return choice.openJob == nil ? .primary : Color(nsColor: .tertiaryLabelColor)
    }

    private var detailColor: Color {
        if isHighlighted { return .white.opacity(0.8) }
        return choice.openJob == nil ? .secondary : Color(nsColor: .tertiaryLabelColor)
    }

    private var accessibilityText: String {
        guard !choice.detail.isEmpty else { return choice.watch.name }
        return "\(choice.watch.name), \(choice.detail)"
    }
}

private struct NewWatchRow: View {
    let name: String
    let isHighlighted: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: UreLayout.rowSpacing) {
                Image(systemName: "plus")
                    .font(.system(size: JobWatchLayout.iconSize, weight: .medium))
                    .frame(width: JobWatchLayout.thumbnailSize)
                Text("New watch named “\(name)”")
                    .font(.system(size: JobWatchLayout.nameSize))
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .foregroundStyle(isHighlighted ? Color.white : Color.accentColor)
            .padding(.horizontal, JobWatchLayout.rowPadding)
            .frame(height: JobWatchLayout.newRowHeight)
            .background(
                isHighlighted ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: JobWatchLayout.rowRadius)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New watch named \(name)")
    }
}

// The AppKit field of the picker. It takes its place in the page's reading order, so Return in
// a new job's title moves here. Return picks the highlighted row, the arrows move the
// highlight, Tab moves on, and Esc clears what you typed.
private struct WatchPickerTextView: NSViewRepresentable {
    let picker: WatchPickerModel
    let isEditable: Bool
    let count: Int
    let pick: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> InPlaceTextField {
        let view = InPlaceTextField(prompt: "Find a watch", style: .body)
        view.delegate = context.coordinator
        view.onBeginEditing = context.coordinator.beginEditing
        view.isEditable = isEditable
        view.stringValue = picker.query
        view.setLabel("Watch")
        view.setAccessibilityIdentifier("jobWatchPicker")
        return view
    }

    func updateNSView(_ view: InPlaceTextField, context: Context) {
        context.coordinator.parent = self
        view.isEditable = isEditable
        if !isEditable, view.currentEditor() != nil { view.window?.makeFirstResponder(nil) }
        if let editor = view.currentEditor() as? NSTextView {
            if editor.string != picker.query { editor.string = picker.query }
        } else if view.stringValue != picker.query {
            view.stringValue = picker.query
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView view: InPlaceTextField, context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? InPlaceLayout.minimumWidth,
            height: view.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: WatchPickerTextView

        init(parent: WatchPickerTextView) { self.parent = parent }

        func beginEditing() { parent.picker.isEditing = true }

        func controlTextDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextField else { return }
            parent.picker.type(view.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.picker.isEditing = false
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                parent.picker.move(by: 1, count: parent.count)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.picker.move(by: -1, count: parent.count)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.pick()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.picker.reset()
                textView.string = ""
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.insertTab(_:)):
                if !InPlaceTextField.moveFocus(from: control, forward: true) {
                    control.window?.selectNextKeyView(nil)
                }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                if !InPlaceTextField.moveFocus(from: control, forward: false) {
                    control.window?.selectPreviousKeyView(nil)
                }
                return true
            default:
                return false
            }
        }
    }
}

// Values from the "6 New job" artboard on the Paper page "Rework · Simple".
private enum JobWatchLayout {
    static let topPadding: CGFloat = 20
    static let rowSpacing: CGFloat = 20
    static let lowerHeight: CGFloat = 24
    static let iconSize: CGFloat = 12
    static let iconSpacing: CGFloat = 8
    static let listGap: CGFloat = 8
    static let listInset: CGFloat = -4
    static let listWidth: CGFloat = 380
    static let listPadding: CGFloat = 6
    static let listRadius: CGFloat = 12
    static let rowHeight: CGFloat = 48
    static let newRowHeight: CGFloat = 36
    static let rowRadius: CGFloat = 8
    static let rowPadding: CGFloat = 8
    static let separatorGap: CGFloat = 4
    static let thumbnailSize: CGFloat = 32
    static let nameSize: CGFloat = 13
    static let detailSize: CGFloat = 11
    static let keySize: CGFloat = 12
}
