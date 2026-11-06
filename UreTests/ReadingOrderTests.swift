import AppKit
import Foundation
import Testing

@testable import Ure

// Tab and Shift-Tab move through a record page in reading order across every place that takes
// input: the one-line fields, the notes texts, such as a part's description, and the paste
// boxes. A part's page laid out like "3 Parts" has its title, then its description beside its
// quantity, then the box that pastes an option, then its notes.
@MainActor
struct ReadingOrderTests {
    @Test
    func tabReachesEveryFieldNotesTextAndPasteBoxInReadingOrder() throws {
        let page = try PartPage()
        #expect(page.window.makeFirstResponder(page.title))
        var reached: [String] = [page.focused]
        while let view = page.focusedView, ReadingOrder.moveFocus(from: view, forward: true) {
            reached.append(page.focused)
        }
        #expect(reached == ["title", "description", "quantity", "pasteOption", "notes"])
        var back: [String] = [page.focused]
        while let view = page.focusedView, ReadingOrder.moveFocus(from: view, forward: false) {
            back.append(page.focused)
        }
        #expect(back == ["notes", "pasteOption", "quantity", "description", "title"])
    }

    @Test
    func tabInANotesTextAndOnAPasteBoxMovesOnInReadingOrder() throws {
        let page = try PartPage()
        let coordinator = NotesTextView.Coordinator(field: page.notesField)
        #expect(page.window.makeFirstResponder(page.description))
        #expect(
            coordinator.textView(
                page.description, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(page.focused == "quantity")
        #expect(page.window.makeFirstResponder(page.notes))
        #expect(
            coordinator.textView(page.notes, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(page.focused == "pasteOption")
        page.paste.keyDown(with: try PartPage.key("\t"))
        #expect(page.focused == "notes")
        #expect(page.window.makeFirstResponder(page.paste))
        page.paste.keyDown(with: try PartPage.key("\u{19}", shift: true))
        #expect(page.focused == "quantity")
    }

    @Test
    func returnInAOneLineFieldMovesToTheNextOneLineFieldAndTabToTheNextStop() throws {
        let page = try PartPage()
        let titleField = FactField(
            label: "Name", prompt: "Name", actionName: "Name", text: "", rule: .anyText,
            queue: page.queue, scope: .parts, edit: { .part(.set(UUID(), .name($0))) })
        let coordinator = InPlaceTextView.Coordinator(field: titleField)
        #expect(page.window.makeFirstResponder(page.title))
        let editor = try #require(page.title.currentEditor() as? NSTextView)
        #expect(
            coordinator.control(
                page.title, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        )
        #expect(page.focused == "quantity")
        #expect(page.window.makeFirstResponder(page.title))
        let again = try #require(page.title.currentEditor() as? NSTextView)
        #expect(
            coordinator.control(
                page.title, textView: again, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(page.focused == "description")
    }

    @Test
    func aMaterialTitleIsAStopAndTabInItMovesOn() throws {
        let page = try PartPage()
        let title = MaterialTitleField()
        title.frame = NSRect(x: 20, y: 110, width: 150, height: 20)
        title.setAccessibilityIdentifier("materialTitle")
        page.window.contentView?.addSubview(title)
        #expect(page.window.makeFirstResponder(page.paste))
        #expect(ReadingOrder.moveFocus(from: page.paste, forward: true))
        #expect(page.focused == "materialTitle")
        let field = AutosaveField(
            text: "", actionName: "Title", queue: page.queue, scope: .parts,
            edit: { .notes(.job(UUID()), $0) })
        let coordinator = MaterialTitleView.Coordinator(field: field) { _, _ in }
        let editor = try #require(title.currentEditor() as? NSTextView)
        #expect(
            coordinator.control(
                title, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(page.focused == "notes")
        #expect(page.window.makeFirstResponder(title))
        let again = try #require(title.currentEditor() as? NSTextView)
        #expect(
            coordinator.control(
                title, textView: again, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(page.focused == "pasteOption")
    }

    @Test
    func aNotesTextThatTakesNoTypingIsNotAStop() throws {
        let page = try PartPage()
        page.description.isEditable = false
        #expect(page.window.makeFirstResponder(page.title))
        #expect(ReadingOrder.moveFocus(from: page.title, forward: true))
        #expect(page.focused == "quantity")
    }
}

// The places on a part's page that take input, laid out top to bottom in a window that is
// never shown.
@MainActor
private struct PartPage {
    let window: NSWindow
    let title: InPlaceTextField
    let description: NotesEditingView
    let quantity: InPlaceTextField
    let readOnly: NotesEditingView
    let paste: OptionPasteStripView
    let notes: NotesEditingView
    let notesField: AutosaveField
    let queue: EditQueue

    init() throws {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = content
        title = Self.field("title", NSRect(x: 20, y: 360, width: 300, height: 24))
        description = Self.text("description", NSRect(x: 20, y: 260, width: 300, height: 60))
        quantity = Self.field("quantity", NSRect(x: 400, y: 296, width: 100, height: 24))
        readOnly = Self.text("readOnly", NSRect(x: 20, y: 200, width: 300, height: 40))
        readOnly.isEditable = false
        paste = OptionPasteStripView(frame: NSRect(x: 20, y: 140, width: 500, height: 40))
        paste.setAccessibilityIdentifier("pasteOption")
        notes = Self.text("notes", NSRect(x: 20, y: 20, width: 500, height: 80))
        // The stops go in out of order, so only their place on the page orders them.
        for view in [notes, paste, readOnly, quantity, description, title] as [NSView] {
            content.addSubview(view)
        }
        queue = EditQueue(
            coordinator: LibraryCoordinator(
                root: URL.temporaryDirectory.appending(path: "UreTests/\(UUID().uuidString)")))
        notesField = AutosaveField(
            text: "", actionName: "Notes", queue: queue, scope: .parts,
            edit: { .notes(.job(UUID()), $0) })
    }

    // The field being typed in, or the view that has the cursor.
    var focusedView: NSView? {
        if let editor = window.firstResponder as? NSTextView,
            let field = editor.delegate as? NSTextField
        {
            return field
        }
        return window.firstResponder as? NSView
    }

    var focused: String { focusedView?.accessibilityIdentifier() ?? "none" }

    static func key(_ characters: String, shift: Bool = false) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 48))
    }

    private static func field(_ identifier: String, _ frame: NSRect) -> InPlaceTextField {
        let field = InPlaceTextField(prompt: identifier, style: .body)
        field.frame = frame
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    private static func text(_ identifier: String, _ frame: NSRect) -> NotesEditingView {
        let view = NotesEditingView.make()
        view.frame = frame
        view.isEditable = true
        view.setAccessibilityIdentifier(identifier)
        return view
    }
}

// A long value ends in "…" at rest and scrolls while you type, so the cursor stays in view.
@MainActor
struct LongValueTests {
    @Test
    func aFieldScrollsWhileYouTypeAndEndsInAnEllipsisAtRest() throws {
        let page = try PartPage()
        let cell = try #require(page.title.cell)
        #expect(!cell.isScrollable && cell.lineBreakMode == .byTruncatingTail)
        #expect(page.window.makeFirstResponder(page.title))
        #expect(cell.isScrollable)
        #expect(page.window.makeFirstResponder(page.quantity))
        #expect(!cell.isScrollable && !cell.wraps && cell.lineBreakMode == .byTruncatingTail)
        #expect(page.window.makeFirstResponder(page.title))
        #expect(page.window.makeFirstResponder(nil))
        #expect(!cell.isScrollable && cell.lineBreakMode == .byTruncatingTail)
    }

    @Test
    func aMaterialTitleDoesTheSame() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let title = MaterialTitleField()
        title.frame = NSRect(x: 10, y: 40, width: 120, height: 20)
        title.stringValue = "Front, with the new crystal fitted.jpg"
        window.contentView?.addSubview(title)
        let cell = try #require(title.cell)
        #expect(!cell.isScrollable && cell.lineBreakMode == .byTruncatingTail)
        #expect(window.makeFirstResponder(title))
        #expect(cell.isScrollable)
        #expect(window.makeFirstResponder(nil))
        #expect(!cell.isScrollable && !cell.wraps && cell.lineBreakMode == .byTruncatingTail)
    }
}
