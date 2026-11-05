import AppKit
import SwiftUI

// The strip under a record's material. Click it, or press Space while it has focus, to choose
// photos and PDFs. Drop files or links on it. A click also gives it focus, so ⌘V then pastes a
// link.
struct MaterialDropStrip: NSViewRepresentable {
    var style = RecordSectionStyle.form
    let choose: () -> Void
    let drop: ([URL]) -> Void
    let paste: (String?) -> Void

    func makeNSView(context: Context) -> MaterialDropStripView {
        let view = MaterialDropStripView(style: style)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MaterialDropStripView, context: Context) {
        view.onChoose = choose
        view.onDrop = drop
        view.onPaste = paste
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView view: MaterialDropStripView, context: Context
    ) -> CGSize? {
        let height = style == .page ? MaterialLayout.pageStripHeight : MaterialLayout.stripHeight
        return CGSize(width: proposal.width ?? 320, height: height)
    }
}

final class MaterialDropStripView: NSView {
    var onChoose: () -> Void = {}
    var onDrop: ([URL]) -> Void = { _ in }
    var onPaste: (String?) -> Void = { _ in }
    var pasteboard = NSPasteboard.general
    private let style: RecordSectionStyle
    private let label: NSHostingView<MaterialDropStripLabel>
    private var isTargeted = false {
        didSet { label.rootView = MaterialDropStripLabel(style: style, isTargeted: isTargeted) }
    }

    init(style: RecordSectionStyle = .form) {
        self.style = style
        label = NSHostingView(rootView: MaterialDropStripLabel(style: style, isTargeted: false))
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        focusRingType = .exterior
        registerForDraggedTypes([.fileURL, .URL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Add material")
        setAccessibilityHelp(
            "Choose photos or PDFs. You can also drop files or links here, or paste a link.")
        setAccessibilityIdentifier("materialDropStrip")
    }

    required init?(coder: NSCoder) { return nil }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onChoose() }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            onChoose()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onChoose()
        return true
    }

    @objc func paste(_ sender: Any?) {
        onPaste(pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string))
    }

    @objc func chooseFiles(_ sender: Any?) { onChoose() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Choose Photos or PDFs…", action: #selector(chooseFiles(_:)),
            keyEquivalent: ""
        ).target = self
        menu.addItem(withTitle: "Paste Link", action: #selector(paste(_:)), keyEquivalent: "")
            .target = self
        return menu
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let radius = style == .page ? MaterialLayout.pageRadius : MaterialLayout.cornerRadius
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !urls(from: sender).isEmpty else { return [] }
        isTargeted = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { isTargeted = false }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isTargeted = false
        let urls = urls(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }

    private func urls(from sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
    }
}

// A form's strip says how to add material on two lines. A page's strip says it on one centred
// line, as on the "4 Watch" artboard.
struct MaterialDropStripLabel: View {
    let style: RecordSectionStyle
    let isTargeted: Bool

    var body: some View {
        Group {
            switch style {
            case .form:
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drop photos or PDFs, or click to choose")
                        Text("Paste a link with ⌘V")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
            case .page:
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    Text("Add photos, PDFs or links, or drop them here")
                }
                .font(.system(size: PageLayout.detailSize))
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MaterialDropStripBorder(style: style, isTargeted: isTargeted))
    }
}

private struct MaterialDropStripBorder: View {
    let style: RecordSectionStyle
    let isTargeted: Bool

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: style == .page ? MaterialLayout.pageRadius : MaterialLayout.cornerRadius)
        shape
            .strokeBorder(
                isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [5, 4])
            )
            .background(
                shape.fill(isTargeted ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear)))
    }
}
