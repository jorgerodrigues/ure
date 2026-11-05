import Foundation

// The facts of one part that you write in place: its name, its description, its quantity and
// its notes. The name and the quantity show on the part's line on its job too. Each saves on its
// own as you type, with Undo.
struct PartFacts {
    let name: FactField
    let description: FactField
    let quantity: FactField
    let notes: AutosaveField

    var editors: [AutosaveField] { [name.editor, description.editor, quantity.editor, notes] }
    var hasUnsavedChanges: Bool { editors.contains { $0.hasUnsavedChanges } }

    static let quantityRule = FactRule(
        problem: { PartQuantity.value(of: $0) == nil ? "Enter a whole number above 0." : nil },
        normalized: { text in PartQuantity.value(of: text).map(String.init) ?? text })

    init(
        part: PartRecord, service: PartService,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        let id = part.id
        name = FactField(
            label: "Name", prompt: "Name", actionName: "Part Name", text: part.name,
            rule: .required("Enter a name."),
            save: { text in _ = try await service.update(id, .name(text)) }, pause: pause)
        description = FactField(
            label: "Description", prompt: "Add a description", actionName: "Description",
            text: part.description ?? "", rule: .anyText,
            save: { text in _ = try await service.update(id, .description(text)) },
            pause: pause)
        quantity = FactField(
            label: "Quantity", prompt: "1", actionName: "Quantity", text: String(part.quantity),
            rule: Self.quantityRule,
            save: { text in _ = try await service.update(id, .quantity(text)) }, pause: pause)
        notes = AutosaveField(
            text: part.notes, actionName: "Notes",
            save: { text in _ = try await service.update(id, .notes(text)) }, pause: pause)
    }

    // Shows the stored values in every field that has nothing waiting to save.
    func refresh(_ part: PartRecord) {
        name.refresh(part.name)
        description.refresh(part.description ?? "")
        quantity.refresh(String(part.quantity))
        notes.refresh(part.notes)
    }
}
