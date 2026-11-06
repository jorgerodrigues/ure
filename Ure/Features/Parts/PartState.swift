import Foundation
import GRDB
import Observation

// Every part in the library: the parts of each job and the spares in the drawer. A part has no
// draft. Its name, description, quantity and notes save on their own as you type. Adding a part,
// moving its state on, using a spare and deleting a part save at once, and ⌘Z undoes each. Every
// change goes through the library's edit queue, in the order you made it.
@Observable
final class PartState {
    static let stageActionName = "Change Part State"
    static let addActionName = "Add Part"
    static let removeActionName = "Delete Part"
    static let spareActionName = "Use Spare"
    static let maximumSpares = 5

    private let service: PartService
    let queue: EditQueue
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    @ObservationIgnored private var entries: [UUID: PartEntry] = [:]
    private(set) var parts: [PartRecord] = []
    private(set) var links: [UUID: [PartLink]] = [:]
    private(set) var facts: [UUID: PartFacts] = [:]
    // The part whose page shows: from the Parts list, or opened from its job's line.
    private(set) var selectedID: UUID?
    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var openError: String?
    // A part just made with ⌘N. Its page puts the cursor in its name.
    private(set) var nameToFocus: UUID?

    init(
        service: PartService, queue: EditQueue,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.queue = queue
        self.pause = pause
        queue.listen { [weak self] change, byUndo in self?.receive(change, byUndo: byUndo) }
    }

    // A part change, such as an added part or a state click, is still saving.
    var isSaving: Bool { queue.isBusy(.parts) }
    var refusal: String? { queue.refusal(in: .parts) }

    var selectedPart: PartRecord? { parts.first { $0.id == selectedID } }

    func part(_ id: UUID?) -> PartRecord? { parts.first { $0.id == id } }

    func facts(for id: UUID) -> PartFacts? { facts[id] }

    func links(of id: UUID) -> [PartLink] { links[id] ?? [] }

    // A job's parts in the order they were added.
    func parts(on jobID: UUID) -> [PartRecord] {
        parts.filter { $0.jobID == jobID }.sorted(by: Self.inOrder)
    }

    // The spares in hand whose name has the typed text, at most five, in order of name. Only a
    // spare in hand can go on a job.
    func spares(matching text: String) -> [PartRecord] {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return [] }
        let found = parts.filter { part in
            part.isSpare && part.stage == .inHand
                && part.name.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive])
                    != nil
        }
        .sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return Array(found.prefix(Self.maximumSpares))
    }

    // The line under a job's parts where you type the next one, made the first time it is
    // asked for.
    func entry(for jobID: UUID) -> PartEntry {
        if let entry = entries[jobID] { return entry }
        let entry = PartEntry(jobID: jobID, queue: queue) { [weak self] text in
            self?.spares(matching: text) ?? []
        }
        entries[jobID] = entry
        return entry
    }

    // Whether a part's notes have the cursor, so ⌘D can type today's date there.
    var isEditingNotes: Bool { facts.values.contains { $0.notes.isEditing } }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            let values = try await queue.coordinator.partValues()
            for try await library in values {
                apply(library)
                isLoading = false
            }
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    func select(_ id: UUID?) {
        selectedID = id
        openError = nil
    }

    func close() { select(nil) }

    func nameFocused() { nameToFocus = nil }

    // Adds a part to the end of a job's parts, Needed. ⌘Z removes it again, and the Undo is
    // registered now, so typing that follows while the part saves comes after it.
    @discardableResult
    func add(
        named name: String, description: String = "", to jobID: UUID,
        undoManager: UndoManager? = nil, then: ((EditResult) -> Void)? = nil
    ) -> EditTicket? {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        return queue.submit(
            .part(.add(name: typed, description: description, job: jobID)), in: .parts,
            undo: Self.addActionName, undoManager: undoManager, then: then)
    }

    // Return on a job's add line adds the typed part, or puts the highlighted spare on the job.
    // The line empties at once, so the next part can follow while this one saves.
    func submitCommand(_ entry: PartEntry, undoManager: UndoManager?) {
        let typed = PartEntryText(name: entry.text, description: entry.description)
        let spare = entry.highlightedID
        entry.clear()
        submit(typed, spare: spare, on: entry, undoManager: undoManager)
    }

    @discardableResult
    func submit(
        _ typed: PartEntryText, spare: UUID?, on entry: PartEntry,
        undoManager: UndoManager? = nil
    ) -> EditTicket? {
        if let spare { return useSpare(spare, on: entry.jobID, undoManager: undoManager) }
        return add(
            named: typed.name, description: typed.description, to: entry.jobID,
            undoManager: undoManager)
    }

    // ⌘N in Parts makes a spare named "New Part", in hand, selects it, and puts the cursor in
    // its name with the name selected, so typing replaces it. Like every New command, it has no
    // Undo. Delete Part takes it away again.
    func makeSpareCommand() { makeSpare() }

    @discardableResult
    func makeSpare() -> EditTicket? {
        guard !isSaving, !isLoading, loadError == nil else { return nil }
        return queue.submit(.part(.add(name: "", description: "", job: nil)), in: .parts) {
            [weak self] result in
            guard let self else { return }
            for case .part(let part) in result.changes {
                select(part.id)
                nameToFocus = part.id
            }
        }
    }

    // Moves a spare in hand from the drawer to the end of a job's parts. ⌘Z puts it back in
    // the drawer.
    @discardableResult
    func useSpare(_ id: UUID, on jobID: UUID, undoManager: UndoManager? = nil) -> EditTicket? {
        guard let spare = part(id), spare.isSpare else { return nil }
        return queue.submit(
            .part(.useSpare(id, job: jobID)), in: .parts, undo: Self.spareActionName,
            undoManager: undoManager)
    }

    func advanceCommand(_ id: UUID, undoManager: UndoManager?) {
        advance(id, undoManager: undoManager)
    }

    // A click on a part's state moves it on, such as Needed to Ordered, and records the day.
    // The stored part decides the next state when the click's turn comes, so two quick clicks
    // move it on twice. ⌘Z puts back the state it had, with its dates.
    @discardableResult
    func advance(_ id: UUID, undoManager: UndoManager? = nil) -> EditTicket? {
        guard part(id)?.stage.next != nil else { return nil }
        return queue.submit(
            .part(.advance(id)), in: .parts, undo: Self.stageActionName,
            undoManager: undoManager)
    }

    func setStageCommand(_ stage: PartStage, of id: UUID, undoManager: UndoManager?) {
        setStage(stage, of: id, undoManager: undoManager)
    }

    // Moves a part to any state from its page's pop-up. The stored part decides whether a
    // choice changes anything, so the last choice always wins. ⌘Z puts back the state it had,
    // with its dates, and Shift-⌘Z the state it was given. Choosing the state the part has,
    // with nothing saving, changes nothing and adds no Undo.
    @discardableResult
    func setStage(_ stage: PartStage, of id: UUID, undoManager: UndoManager? = nil)
        -> EditTicket?
    {
        guard let current = part(id) else { return nil }
        if !isSaving, current.stage == stage { return nil }
        return queue.submit(
            .part(.stage(id, stage)), in: .parts, undo: Self.stageActionName,
            undoManager: undoManager)
    }

    func removeCommand(_ id: UUID, undoManager: UndoManager?) {
        remove(id, undoManager: undoManager)
    }

    // Deletes a part with its links. ⌘Z puts both back. Typing on the part saves first, so
    // Undo brings it back too. A text the part does not take, such as a quantity of 0, goes
    // with the part.
    @discardableResult
    func remove(_ id: UUID, undoManager: UndoManager? = nil) -> EditTicket? {
        guard part(id) != nil else { return nil }
        return queue.submit(
            .part(.remove(id)), in: .parts, undo: Self.removeActionName, undoManager: undoManager)
    }

    func openLink(_ link: PartLink) {
        openError = nil
        do { try service.open(link) } catch { openError = error.localizedDescription }
    }

    private func receive(_ change: LibraryChange, byUndo: Bool) {
        switch change {
        case .part(let record): adopt(record, force: byUndo)
        case .partRemoved(let id): discard(id)
        default: break
        }
    }

    // A part that leaves takes its fields with it, and text they never took goes too. Undo of
    // typing on it later comes from the stored data, so it needs no field.
    private func discard(_ id: UUID) {
        parts.removeAll { $0.id == id }
        links[id] = nil
        facts.removeValue(forKey: id)?.discard()
        if selectedID == id { selectedID = nil }
    }

    private func adopt(_ record: PartRecord, force: Bool = false) {
        var records = parts
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        apply(PartLibrary(parts: records, links: links), forcing: force ? record.id : nil)
    }

    // The library can report a list from before an edit after the edit's own result. A part it
    // leaves out keeps fields with typing on them, which the next report brings back.
    private func apply(_ library: PartLibrary, forcing forced: UUID? = nil) {
        parts = library.parts
        links = library.links
        let kept = Set(library.parts.map(\.id))
        for (id, fields) in facts where !kept.contains(id) && !fields.hasUnsavedText {
            facts[id] = nil
        }
        for part in library.parts {
            if let existing = facts[part.id] {
                existing.refresh(part, force: part.id == forced)
            } else {
                facts[part.id] = PartFacts(part: part, queue: queue, pause: pause)
            }
        }
    }

    private static func inOrder(_ lhs: PartRecord, _ rhs: PartRecord) -> Bool {
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

// A part typed on a job's add line: its name and, after Tab, its description.
nonisolated struct PartEntryText: Equatable, Sendable {
    let name: String
    var description = ""
}

// The line under a job's parts where you type the next part's name, and after Tab its
// description. As you type the name, the spares in hand whose name has the text show under it.
// Return adds a part with the typed name and description, and the line is empty again for the
// next one. The Down arrow highlights a spare, and Return then puts that spare on the job
// instead.
@Observable
final class PartEntry {
    let jobID: UUID
    private(set) var text = ""
    private(set) var description = ""
    // The spare that Return takes, or nil when Return adds a new part.
    private(set) var highlightedID: UUID?
    private(set) var isEditing = false
    @ObservationIgnored private let queue: EditQueue
    @ObservationIgnored private let findSpares: (String) -> [PartRecord]

    init(jobID: UUID, queue: EditQueue, findSpares: @escaping (String) -> [PartRecord]) {
        self.jobID = jobID
        self.queue = queue
        self.findSpares = findSpares
    }

    var spares: [PartRecord] { isEditing ? findSpares(text) : [] }

    // No name typed and no spare highlighted, so Return has nothing to add.
    var isBlank: Bool {
        highlightedID == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Either field of the line has the cursor.
    var isTyping: Bool { isEditing || isEditingDescription }
    private(set) var isEditingDescription = false

    func beginDescription() {
        isEditingDescription = true
        isTypingBurst = false
    }
    func endDescription() { isEditingDescription = false }
    func changeDescription(to newText: String, undoManager: UndoManager? = nil) {
        guard newText != description else { return }
        registerTyping(undoManager)
        description = newText
    }

    // Each time the cursor comes to the line, the typing that follows is a new Undo step.
    func beginEditing() {
        isEditing = true
        isTypingBurst = false
    }

    func endEditing() {
        isEditing = false
        highlightedID = nil
    }

    func change(to newText: String, undoManager: UndoManager? = nil) {
        if newText != text { registerTyping(undoManager) }
        text = newText
        if let highlightedID, !spares.contains(where: { $0.id == highlightedID }) {
            self.highlightedID = nil
        }
    }

    // The arrows move the highlight through the spares. Up from the first one leaves none
    // highlighted, so Return adds the typed part.
    func moveHighlight(down: Bool) {
        let found = spares
        guard !found.isEmpty else { return }
        let index = found.firstIndex { $0.id == highlightedID }
        if down {
            let next = index.map { min($0 + 1, found.count - 1) } ?? 0
            highlightedID = found[next].id
        } else if let index, index > 0 {
            highlightedID = found[index - 1].id
        } else {
            highlightedID = nil
        }
    }

    func highlight(_ id: UUID?) { highlightedID = id }

    // Empties the line for the next part.
    // The typing on the line is gone, so its Undo goes too, and ⌘Z reaches the part it added.
    func clear() {
        text = ""
        description = ""
        highlightedID = nil
        endTyping()
    }

    // Each burst of typing on the line is one Undo step, so ⌘Z undoes the typing before it
    // reaches a part added earlier. Redo puts the typing back. The line saves nowhere, so the
    // queue keeps its Undo steps with the texts to put back, and drops them when the line is
    // submitted or emptied.
    @ObservationIgnored private var isTypingBurst = false

    private func registerTyping(_ undoManager: UndoManager?) {
        guard let undoManager, !isTypingBurst else { return }
        isTypingBurst = true
        queue.registerLocalTyping(
            jobID, restoring: [text, description],
            actionName: PartEntryWording.typingActionName, undoManager: undoManager
        ) { [weak self] texts in self?.restore(texts) ?? texts }
    }

    // Puts back the texts of an Undo or Redo, and gives the texts it had, for the way back.
    private func restore(_ texts: [String]) -> [String] {
        let current = [text, description]
        isTypingBurst = false
        text = texts.first ?? ""
        description = texts.dropFirst().first ?? ""
        highlightedID = nil
        return current
    }

    private func endTyping() {
        isTypingBurst = false
        queue.removeLocalTyping(jobID)
    }
}
