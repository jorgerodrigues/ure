import AppKit

// A place on a record page that Tab and Shift-Tab stop at: an in-place field, a notes text, or a
// box you paste or drop into. It is a stop only while it takes input.
protocol ReadingOrderStop: NSView {
    var takesReadingOrderFocus: Bool { get }
}

// Tab and Shift-Tab move through a record page in reading order, top to bottom and then left to
// right, across every stop on the page. So the keyboard alone reaches each field, each notes
// text and each paste box, as the "7 Typing" rules ask.
enum ReadingOrder {
    // Moves focus to the next or previous stop. False when there is none in that direction.
    // A stop can skip others on its way, such as a part's add line moving past its own
    // description to the checklist.
    static func moveFocus(
        from view: NSView, forward: Bool, skipping skipped: (NSView) -> Bool = { _ in false }
    ) -> Bool {
        guard let window = view.window, let content = window.contentView else { return false }
        let stops = self.stops(in: content).sorted(by: isInReadingOrder)
            .filter { $0 === view || !skipped($0) }
        guard let index = stops.firstIndex(where: { $0 === view }) else { return false }
        let target = forward ? index + 1 : index - 1
        guard stops.indices.contains(target) else { return false }
        return window.makeFirstResponder(stops[target])
    }

    // Tab or Shift-Tab pressed on a stop that has no text, such as a paste box. False for any
    // other key.
    static func moveFocus(for event: NSEvent, from view: NSView) -> Bool {
        let forward: Bool
        switch event.charactersIgnoringModifiers {
        case "\t": forward = !event.modifierFlags.contains(.shift)
        case "\u{19}": forward = false
        default: return false
        }
        if !moveFocus(from: view, forward: forward) {
            if forward {
                view.window?.selectNextKeyView(nil)
            } else {
                view.window?.selectPreviousKeyView(nil)
            }
        }
        return true
    }

    private static func stops(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        if let stop = view as? any ReadingOrderStop, stop.takesReadingOrderFocus,
            !view.isHiddenOrHasHiddenAncestor
        {
            found.append(view)
        }
        for child in view.subviews { found += stops(in: child) }
        return found
    }

    private static func isInReadingOrder(_ lhs: NSView, _ rhs: NSView) -> Bool {
        let left = lhs.convert(lhs.bounds, to: nil)
        let right = rhs.convert(rhs.bounds, to: nil)
        if abs(left.maxY - right.maxY) > 1 { return left.maxY > right.maxY }
        return left.minX < right.minX
    }
}
