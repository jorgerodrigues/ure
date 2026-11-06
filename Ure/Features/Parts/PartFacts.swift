import Foundation

// The facts of one part that you write in place: its name, its description, its quantity and
// its notes. The name and the quantity show on the part's line on its job too. Each saves on its
// own as you type, as an edit on the library's queue, with Undo.
struct PartFacts {
    let name: FactField
    // The description can take several lines, such as a maker's reference and its sizes.
    let description: AutosaveField
    let quantity: FactField
    let notes: AutosaveField

    var editors: [AutosaveField] { [name.editor, description, quantity.editor, notes] }
    // A field holds text that has not saved, such as a quantity of 0.
    var hasUnsavedText: Bool { editors.contains(where: \.hasUnsavedText) }
    // A field holds text whose save failed. It can be tried again.
    var hasFailedText: Bool { editors.contains(where: \.hasFailedText) }

    // Tries text whose save failed once more.
    func saveFailedText() {
        for editor in editors { editor.saveFailedText() }
    }

    static let quantityRule = FactRule(
        problem: { PartQuantity.value(of: $0) == nil ? "Enter a whole number above 0." : nil },
        normalized: { text in PartQuantity.value(of: text).map(String.init) ?? text })

    init(
        part: PartRecord, queue: EditQueue,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        let id = part.id
        name = FactField(
            label: "Name", prompt: "Name", actionName: "Part Name", text: part.name,
            rule: .required("Enter a name."), queue: queue, scope: .parts,
            edit: { .part(.set(id, .name($0))) }, pause: pause)
        description = AutosaveField(
            text: part.description ?? "", actionName: "Description", queue: queue,
            scope: .parts, edit: { .part(.set(id, .description($0))) }, pause: pause)
        quantity = FactField(
            label: "Quantity", prompt: "1", actionName: "Quantity", text: String(part.quantity),
            rule: Self.quantityRule, queue: queue, scope: .parts,
            edit: { .part(.set(id, .quantity($0))) }, pause: pause)
        notes = AutosaveField(
            text: part.notes, actionName: "Notes", queue: queue, scope: .parts,
            edit: { .part(.set(id, .notes($0))) }, pause: pause)
    }

    // Shows the stored values in every field that has nothing waiting to save. After Undo and
    // Redo the fields take them also while one has the cursor.
    func refresh(_ part: PartRecord, force: Bool = false) {
        name.refresh(part.name, force: force)
        description.refresh(part.description ?? "", force: force)
        quantity.refresh(String(part.quantity), force: force)
        notes.refresh(part.notes, force: force)
    }

    // The part goes, and text it never took goes with it.
    func discard() {
        for editor in editors { editor.discard() }
    }
}
