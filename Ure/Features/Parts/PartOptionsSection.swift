import AppKit
import SwiftUI

// A part's buying options on its page, as on the "3 Parts" artboard: each supplier with its
// note, and its price with shipping on the right, in the home currency when a rate is set. The
// lowest is marked Lowest. A click on an option shows its fields, written in place. Pasting a
// link in the box under them adds an option.
struct PartOptionsSection: View {
    @Environment(PartState.self) private var parts
    @Environment(MoneyState.self) private var money
    let part: PartRecord
    let isEditable: Bool

    var body: some View {
        let options = parts.options(of: part.id)
        VStack(alignment: .leading, spacing: PageLayout.headingSpacing) {
            PageSectionHeading(
                title: "Options", detail: options.isEmpty ? nil : "Price with shipping")
            PartOptionCards(
                options: options, lowestID: PartPricing.lowest(options, rates: money.rates),
                isEditable: isEditable)
            if isEditable {
                PartOptionPasteStrip(partID: part.id)
            } else if options.isEmpty {
                Text("No options").foregroundStyle(.secondary)
            }
            if let error = parts.optionError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: NotesLayout.failureSize))
                    .foregroundStyle(.red)
            }
            if options.contains(where: { $0.currency.map { $0 != money.home } ?? false }) {
                Text(PartOptionWording.estimateNote(home: money.home))
                    .font(.system(size: PartOptionLayout.smallSize))
                    .foregroundStyle(.secondary)
                    .padding(.top, PartOptionLayout.noteTop)
            }
        }
    }
}

// The option cards, in the order they were added. An option whose deletion is saving takes no
// edits.
struct PartOptionCards: View {
    @Environment(PartState.self) private var parts
    let options: [PartOption]
    let lowestID: UUID?
    let isEditable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PartOptionLayout.cardSpacing) {
            ForEach(options) { option in
                PartOptionCard(
                    option: option, isLowest: option.id == lowestID,
                    isEditable: isEditable && parts.canEdit(option))
            }
        }
    }
}

// One option: its supplier's initial, the supplier with Lowest when it is the lowest, its note,
// and its price with shipping. A click shows or hides its fields.
private struct PartOptionCard: View {
    @Environment(PartState.self) private var parts
    @Environment(MoneyState.self) private var money
    let option: PartOption
    let isLowest: Bool
    let isEditable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { summary }
                .buttonStyle(.plain)
                .help(isOpen ? "Hide the option’s details" : "Show the option’s details")
                .accessibilityLabel(accessibilityTitle)
                .accessibilityHint(
                    isOpen ? "Hides the option’s fields" : "Shows the option’s fields"
                )
                .accessibilityIdentifier("partOption-\(option.id.uuidString)")
            if isOpen, let facts = parts.facts(forOption: option.id) {
                Divider()
                PartOptionFields(option: option, facts: facts, isEditable: isEditable)
                    .padding(PartOptionLayout.fieldsPadding)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: PartOptionLayout.cardRadius)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .contextMenu { PartOptionMenu(option: option, isEditable: isEditable) }
        .zIndex(isOpen ? 1 : 0)
    }

    private var isOpen: Bool { parts.openOptionID == option.id }

    private var summary: some View {
        HStack(spacing: PartOptionLayout.cardGap) {
            SupplierInitial(supplier: option.supplier)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(option.supplier)
                        .font(.system(size: PartOptionLayout.supplierSize, weight: .semibold))
                        .lineLimit(1)
                    if isLowest { LowestBadge() }
                }
                if !option.note.isEmpty {
                    Text(option.note)
                        .font(.system(size: PageLayout.detailSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                if let headline = PartMoneyWording.headline(of: option, rates: money.rates) {
                    Text(headline)
                        .font(.system(size: PageLayout.headingSize, weight: .semibold))
                        .monospacedDigit()
                        .fixedSize()
                }
                if let breakdown = PartMoneyWording.breakdown(of: option, rates: money.rates) {
                    Text(breakdown)
                        .font(.system(size: PartOptionLayout.smallSize))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            // The prices take the room they need, so a long currency never breaks a line.
            .frame(minWidth: PartOptionLayout.priceWidth, alignment: .trailing)
            .layoutPriority(1)
        }
        .padding(.vertical, PartOptionLayout.cardVertical)
        .padding(.horizontal, PartOptionLayout.cardHorizontal)
        .contentShape(Rectangle())
    }

    private var accessibilityTitle: String {
        [
            option.supplier, isLowest ? "Lowest" : nil, option.note.isEmpty ? nil : option.note,
            PartMoneyWording.headline(of: option, rates: money.rates),
            PartMoneyWording.breakdown(of: option, rates: money.rates),
        ].compactMap { $0 }.joined(separator: ", ")
    }

    private func toggle() { parts.openOption(isOpen ? nil : option.id) }
}

// An open option's fields: its supplier, price, shipping and currency, its note, and its link
// with Open and Delete Option.
private struct PartOptionFields: View {
    @Environment(PartState.self) private var parts
    @Environment(\.undoManager) private var undoManager
    let option: PartOption
    let facts: PartOptionFacts
    let isEditable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PartOptionLayout.fieldRowSpacing) {
            HStack(alignment: .top, spacing: PartOptionLayout.fieldSpacing) {
                FactRow(
                    field: facts.supplier, isEditable: isEditable,
                    identifier: "optionSupplier-\(option.id.uuidString)"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                FactRow(
                    field: facts.price, isEditable: isEditable,
                    identifier: "optionPrice-\(option.id.uuidString)",
                    requestsFocus: parts.priceToFocus == option.id, didFocus: parts.priceFocused,
                    showsHint: false
                )
                .frame(width: PartOptionLayout.amountWidth, alignment: .leading)
                FactRow(
                    field: facts.shipping, isEditable: isEditable,
                    identifier: "optionShipping-\(option.id.uuidString)", showsHint: false
                )
                .frame(width: PartOptionLayout.amountWidth, alignment: .leading)
                OptionCurrencyPopUp(option: option, isEditable: isEditable)
            }
            .padding(.leading, -InPlaceLayout.inset)
            FactRow(
                field: facts.note, isEditable: isEditable,
                identifier: "optionNote-\(option.id.uuidString)"
            )
            .padding(.leading, -InPlaceLayout.inset)
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(option.url).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Open Link", action: open)
                    .accessibilityLabel("Open \(option.url) in browser")
                    .accessibilityIdentifier("openOption-\(option.id.uuidString)")
                Button(PartState.removeOptionActionName, role: .destructive, action: remove)
                    .disabled(!isEditable)
                    .accessibilityIdentifier("deleteOption-\(option.id.uuidString)")
            }
            .font(.system(size: PageLayout.detailSize))
            if let error = parts.openError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
    }

    private func open() { parts.openLink(option.url) }
    private func remove() { parts.removeOptionCommand(option.id, undoManager: undoManager) }
}

// The currency an option's price and shipping are in, as a pop-up. The home currency and the
// currencies the library uses come first, then every other currency.
private struct OptionCurrencyPopUp: View {
    @Environment(PartState.self) private var parts
    @Environment(MoneyState.self) private var money
    @Environment(\.undoManager) private var undoManager
    let option: PartOption
    let isEditable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: InPlaceLayout.labelSpacing) {
            Text("Currency")
                .font(.system(size: InPlaceLayout.labelSize, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Menu {
                CurrencyMenuItems(
                    first: [money.home] + money.settings.usedCurrencies, choose: choose)
            } label: {
                Text(shown).font(.system(size: PageLayout.detailSize, weight: .medium))
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(!isEditable)
            .frame(height: InPlaceLayout.boxHeight)
            .accessibilityLabel("Currency")
            .accessibilityValue(CurrencyRules.name(of: shown))
            .accessibilityIdentifier("optionCurrency-\(option.id.uuidString)")
        }
    }

    private var shown: String { option.currency ?? money.home }

    private func choose(_ code: String) {
        parts.chooseCurrencyCommand(code, of: option.id, undoManager: undoManager)
    }
}

// Currencies to choose from: the ones given first, then every other one in a submenu.
struct CurrencyMenuItems: View {
    let first: [String]
    let choose: (String) -> Void

    var body: some View {
        let leading = first.reduce(into: [String]()) { list, code in
            if CurrencyRules.isKnown(code), !list.contains(code) { list.append(code) }
        }
        if leading.isEmpty {
            ForEach(CurrencyRules.codes, id: \.self) { code in
                Button(CurrencyMenuItems.title(of: code)) { choose(code) }
            }
        } else {
            ForEach(leading, id: \.self) { code in
                Button(CurrencyMenuItems.title(of: code)) { choose(code) }
            }
            Divider()
            Menu("Other Currencies") {
                ForEach(CurrencyRules.codes.filter { !leading.contains($0) }, id: \.self) {
                    code in
                    Button(CurrencyMenuItems.title(of: code)) { choose(code) }
                }
            }
        }
    }

    // A currency in a menu, such as "GBP · British Pound".
    static func title(of code: String) -> String { "\(code) · \(CurrencyRules.name(of: code))" }
}

// An option's right-click menu.
private struct PartOptionMenu: View {
    @Environment(PartState.self) private var parts
    @Environment(\.undoManager) private var undoManager
    let option: PartOption
    let isEditable: Bool

    var body: some View {
        Button("Open Link") { parts.openLink(option.url) }
        Divider()
        Button(PartState.removeOptionActionName, role: .destructive) {
            parts.removeOptionCommand(option.id, undoManager: undoManager)
        }
        .disabled(!isEditable)
    }
}

// The first letter of a supplier on a small white tile, in a colour of its own.
private struct SupplierInitial: View {
    let supplier: String

    var body: some View {
        RoundedRectangle(cornerRadius: PartOptionLayout.initialRadius)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: PartOptionLayout.initialRadius)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .overlay {
                Text(supplier.first.map(String.init) ?? "·")
                    .font(.system(size: PageLayout.detailSize, weight: .bold))
                    .foregroundStyle(Self.colour(of: supplier))
            }
            .frame(width: PartOptionLayout.initialSize, height: PartOptionLayout.initialSize)
            .accessibilityHidden(true)
    }

    private static let colours: [NSColor] = [
        .systemBlue, .systemBrown, .systemGreen, .systemIndigo, .systemOrange, .systemTeal,
        .systemPurple, .systemRed,
    ]

    // The same supplier always gets the same colour, from an FNV-1a hash of its name.
    private static func colour(of supplier: String) -> Color {
        var hash: UInt32 = 2_166_136_261
        for byte in supplier.lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Color(nsColor: colours[Int(hash % UInt32(colours.count))])
    }
}

private struct LowestBadge: View {
    var body: some View {
        Text("Lowest")
            .font(.system(size: InPlaceLayout.labelSize, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(
                Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
    }
}

// The box under the options. Click it, or give it focus and press ⌘V, to add the link on the
// pasteboard as an option. Links dropped on it are added too.
private struct PartOptionPasteStrip: View {
    @Environment(PartState.self) private var parts
    @Environment(\.undoManager) private var undoManager
    let partID: UUID

    var body: some View {
        OptionPasteStrip(paste: paste)
            .frame(height: PartOptionLayout.stripHeight)
    }

    private func paste(_ text: String?) {
        parts.pasteOptionCommand(text, on: partID, undoManager: undoManager)
    }
}

private struct OptionPasteStrip: NSViewRepresentable {
    let paste: (String?) -> Void

    func makeNSView(context: Context) -> OptionPasteStripView {
        let view = OptionPasteStripView()
        view.onPaste = paste
        return view
    }

    func updateNSView(_ view: OptionPasteStripView, context: Context) { view.onPaste = paste }
}

final class OptionPasteStripView: NSView, ReadingOrderStop {
    var onPaste: (String?) -> Void = { _ in }
    var pasteboard = NSPasteboard.general
    private let label = NSHostingView(rootView: OptionPasteStripLabel(isTargeted: false))
    private var isTargeted = false {
        didSet { label.rootView = OptionPasteStripLabel(isTargeted: isTargeted) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        focusRingType = .exterior
        registerForDraggedTypes([.URL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(PartOptionWording.pastePrompt)
        setAccessibilityHelp("Adds the link you copied as a buying option.")
        setAccessibilityIdentifier("pasteOption")
    }

    required init?(coder: NSCoder) { return nil }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { paste(nil) }
    }

    var takesReadingOrderFocus: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            paste(nil)
        } else if !ReadingOrder.moveFocus(for: event, from: self) {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        paste(nil)
        return true
    }

    @objc func paste(_ sender: Any?) {
        onPaste(pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Paste Link", action: #selector(paste(_:)), keyEquivalent: "")
            .target = self
        return menu
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds, xRadius: PartOptionLayout.cardRadius,
            yRadius: PartOptionLayout.cardRadius
        ).fill()
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
        for url in urls { onPaste(url.absoluteString) }
        return true
    }

    private func urls(from sender: any NSDraggingInfo) -> [URL] {
        let read = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        return (read ?? []).filter { !$0.isFileURL }
    }
}

private struct OptionPasteStripLabel: View {
    let isTargeted: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PartOptionLayout.cardRadius)
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 12, weight: .medium))
            Text(PartOptionWording.pastePrompt)
        }
        .font(.system(size: PageLayout.detailSize))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            shape.strokeBorder(
                isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [5, 4])
            )
        )
    }
}

enum PartOptionWording {
    static let pastePrompt = "Paste a link to add an option"

    // The line under the options when one is in another currency.
    static func estimateNote(home: String) -> String {
        "Prices in other currencies show an estimate in \(home), from a rate you set once per currency in Settings."
    }
}

// Values from the "3 Parts" artboard on the Paper page "Rework · Simple".
enum PartOptionLayout {
    static let cardSpacing: CGFloat = 8
    static let cardRadius: CGFloat = 12
    static let cardGap: CGFloat = 14
    static let cardVertical: CGFloat = 14
    static let cardHorizontal: CGFloat = 16
    static let initialSize: CGFloat = 32
    static let initialRadius: CGFloat = 8
    static let supplierSize: CGFloat = 15
    static let smallSize: CGFloat = 12
    static let priceWidth: CGFloat = 150
    static let stripHeight: CGFloat = 52
    static let noteTop: CGFloat = 4
    static let fieldsPadding: CGFloat = 16
    static let fieldSpacing: CGFloat = 16
    static let fieldRowSpacing: CGFloat = 14
    static let amountWidth: CGFloat = 120
}
