import Foundation
import GRDB
import Observation

// Every part in the library: the parts of each job and the spares in the drawer. A part has no
// draft. Its name, description, quantity and notes save on their own as you type. Adding a part,
// moving its state on, using a spare and deleting a part save at once, and ⌘Z undoes each.
@Observable
final class PartState {
    static let stageActionName = "Change Part State"
    static let addActionName = "Add Part"
    static let removeActionName = "Delete Part"
    static let spareActionName = "Use Spare"
    static let maximumSpares = 5

    private let service: PartService
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    @ObservationIgnored private let stages = ChangeUndo<PartStageValue>()
    @ObservationIgnored private let placements = ChangeUndo<PartPlacement>()
    // Whether a part is in the library. Undo of an added part removes it, and Undo of a
    // removal puts it back.
    @ObservationIgnored private let presence = ChangeUndo<Bool>()
    @ObservationIgnored private var removed: [UUID: RemovedPart] = [:]
    @ObservationIgnored private var entries: [UUID: PartEntry] = [:]
    private(set) var parts: [PartRecord] = []
    private(set) var links: [UUID: [PartLink]] = [:]
    private(set) var facts: [UUID: PartFacts] = [:]
    // The part whose page shows: from the Parts list, or opened from its job's line.
    private(set) var selectedID: UUID?
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var openError: String?
    // A part just made with ⌘N. Its page puts the cursor in its name.
    private(set) var nameToFocus: UUID?

    init(
        service: PartService,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.pause = pause
    }

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
        let entry = PartEntry(jobID: jobID) { [weak self] text in
            self?.spares(matching: text) ?? []
        }
        entries[jobID] = entry
        return entry
    }

    // Typing that has not saved yet: a part's fields, and part names that did not save.
    var hasUnsavedFacts: Bool {
        facts.values.contains { $0.hasUnsavedChanges }
            || entries.values.contains { !$0.unsaved.isEmpty }
    }

    // Whether a part's notes have the cursor, so ⌘D can type today's date there.
    var isEditingNotes: Bool { facts.values.contains { $0.notes.isEditing } }

    func observe() async {
        isLoading = true
        loadError = nil
        do {
            let values = try await service.coordinator.partValues()
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

    // Adds a part to the end of a job's parts, Needed. ⌘Z removes it again.
    @discardableResult
    func add(
        named name: String, description: String = "", to jobID: UUID,
        undoManager: UndoManager? = nil
    ) async -> PartRecord? {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        // Parts typed one after another save one at a time, in the order they were typed.
        var made: PartRecord?
        _ = await presence.perform(true) { [weak self] _ in
            made = await self?.make(named: typed, description: description, on: jobID)
            return made != nil
        }
        guard let made else { return nil }
        registerPresence(of: made.id, setting: false, actionName: Self.addActionName, undoManager)
        return made
    }

    // Return on a job's add line adds the typed part, or puts the highlighted spare on the job.
    // The line empties at once, so the next part can follow while this one saves.
    func submitCommand(_ entry: PartEntry, undoManager: UndoManager?) {
        let typed = PartEntryText(name: entry.text, description: entry.description)
        let spare = entry.highlightedID
        entry.clear()
        Task { await submit(typed, spare: spare, on: entry, undoManager: undoManager) }
    }

    // A part that did not save stays under the line, with Try Again, also while you type the
    // next one. A spare that could not be used stays in the drawer.
    @discardableResult
    func submit(
        _ typed: PartEntryText, spare: UUID?, on entry: PartEntry,
        undoManager: UndoManager? = nil
    ) async -> Bool {
        if let spare { return await useSpare(spare, on: entry.jobID, undoManager: undoManager) }
        guard await save(typed, on: entry, undoManager: undoManager) else {
            entry.keepUnsaved(typed)
            return false
        }
        return true
    }

    func retryUnsavedCommand(_ entry: PartEntry, undoManager: UndoManager?) {
        Task { await retryUnsaved(entry, undoManager: undoManager) }
    }

    // Adds the names that did not save, in the order they were typed, until one fails again.
    // Each name leaves the line before it is added, so a second Try Again never adds it twice.
    // True when every name saved.
    @discardableResult
    func retryUnsaved(_ entry: PartEntry, undoManager: UndoManager? = nil) async -> Bool {
        while let typed = entry.takeUnsaved() {
            guard await save(typed, on: entry, undoManager: undoManager) else {
                entry.putBackUnsaved(typed)
                return false
            }
        }
        return true
    }

    private func save(_ typed: PartEntryText, on entry: PartEntry, undoManager: UndoManager?)
        async -> Bool
    {
        await add(
            named: typed.name, description: typed.description, to: entry.jobID,
            undoManager: undoManager) != nil
    }

    // ⌘N in Parts makes a spare named "New Part", in hand, selects it, and puts the cursor in
    // its name with the name selected, so typing replaces it. Like every New command, it has no
    // Undo. Delete Part takes it away again.
    func makeSpareCommand() { Task { await makeSpare() } }

    @discardableResult
    func makeSpare() async -> PartRecord? {
        guard !isSaving, !isLoading, loadError == nil else { return nil }
        guard let part = await make(named: "", description: "", on: nil) else { return nil }
        select(part.id)
        nameToFocus = part.id
        return part
    }

    // Moves a spare in hand from the drawer to the end of a job's parts. ⌘Z puts it back in
    // the drawer.
    @discardableResult
    func useSpare(_ id: UUID, on jobID: UUID, undoManager: UndoManager? = nil) async -> Bool {
        guard let spare = part(id), spare.isSpare else { return false }
        let prior = PartPlacement(part: spare)
        return await placements.perform(prior) { [weak self] _ in
            await self?.placeSpare(id, on: jobID, prior: prior, undoManager: undoManager) ?? false
        }
    }

    func advanceCommand(_ id: UUID, undoManager: UndoManager?) {
        Task { await advance(id, undoManager: undoManager) }
    }

    // A click on a part's state moves it on, such as Needed to Ordered, and records the day.
    // The next state comes from the stored part once the changes before it have saved, so two
    // quick clicks move it on twice. ⌘Z puts back the state it had, with its dates.
    @discardableResult
    func advance(_ id: UUID, undoManager: UndoManager? = nil) async -> Bool {
        guard let next = part(id)?.stage.next else { return false }
        return await stages.perform(PartStageValue(stage: next)) { [weak self] _ in
            await self?.changeStage(id, undoManager: undoManager) { try await $0.advance(id) }
                ?? false
        }
    }

    func setStageCommand(_ stage: PartStage, of id: UUID, undoManager: UndoManager?) {
        Task { await setStage(stage, of: id, undoManager: undoManager) }
    }

    // Moves a part to any state from its page's pop-up. ⌘Z puts back the state it had, with its
    // dates, and Shift-⌘Z the state it was given.
    @discardableResult
    func setStage(_ stage: PartStage, of id: UUID, undoManager: UndoManager? = nil) async
        -> Bool
    {
        guard let existing = part(id), existing.stage != stage else { return false }
        return await stages.perform(PartStageValue(stage: stage)) { [weak self] _ in
            await self?.changeStage(id, undoManager: undoManager) {
                try await $0.setStage(id, to: stage)
            } ?? false
        }
    }

    // Waits for a state change that Undo or Redo started.
    func waitForStageChanges() async { await stages.wait() }

    func removeCommand(_ id: UUID, undoManager: UndoManager?) {
        Task { await remove(id, undoManager: undoManager) }
    }

    // Deletes a part with its links. ⌘Z puts both back.
    @discardableResult
    func remove(_ id: UUID, undoManager: UndoManager? = nil) async -> Bool {
        guard part(id) != nil else { return false }
        let removed = await presence.perform(false) { [weak self] _ in
            await self?.setPresence(of: id, to: false) ?? false
        }
        guard removed else { return false }
        registerPresence(of: id, setting: true, actionName: Self.removeActionName, undoManager)
        return true
    }

    // Waits for an addition or a removal that Undo or Redo started.
    func waitForPresenceChanges() async {
        await presence.wait()
        await placements.wait()
    }

    func openLink(_ link: PartLink) {
        openError = nil
        do { try service.open(link) } catch { openError = error.localizedDescription }
    }

    func saveFactsNow() {
        for editor in unsavedEditors { editor.saveNow() }
    }

    // Saves every field and tries the part names that did not save again. False while any
    // typing is still unsaved, so quitting asks first.
    func saveAllFacts() async -> Bool {
        var succeeded = true
        for editor in unsavedEditors {
            if await !editor.flush() { succeeded = false }
        }
        for entry in entries.values where !entry.unsaved.isEmpty {
            if await !retryUnsaved(entry) { succeeded = false }
        }
        return succeeded
    }

    func discardUndo() {
        for facts in facts.values {
            for editor in facts.editors { editor.discardUndo() }
        }
        stages.discardUndo()
        placements.discardUndo()
        presence.discardUndo()
        removed = [:]
    }

    private var unsavedEditors: [AutosaveField] {
        facts.values.flatMap(\.editors).filter(\.hasUnsavedChanges)
    }

    private func make(named name: String, description: String, on jobID: UUID?) async
        -> PartRecord?
    {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let part = try await service.add(named: name, description: description, to: jobID)
            adopt(part)
            return part
        } catch {
            saveError = error.localizedDescription
            return nil
        }
    }

    private func changeStage(
        _ id: UUID, undoManager: UndoManager?,
        write: (PartService) async throws -> PartStageChange
    ) async -> Bool {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let change = try await write(service)
            adopt(change.part)
            let next = PartStageValue(part: change.part)
            guard next != change.prior else { return true }
            let restore: ChangeUndo<PartStageValue>.Write = { [weak self] value in
                await self?.restoreStage(id, to: value) ?? false
            }
            stages.registerUndo(
                setting: change.prior, redoing: next, actionName: Self.stageActionName,
                undoManager: undoManager, write: restore)
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func restoreStage(_ id: UUID, to value: PartStageValue) async -> Bool {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            adopt(try await service.restoreStage(id, to: value))
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func placeSpare(
        _ id: UUID, on jobID: UUID, prior: PartPlacement, undoManager: UndoManager?
    ) async -> Bool {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let placed = try await service.useSpare(id, on: jobID)
            adopt(placed)
            let restore: ChangeUndo<PartPlacement>.Write = { [weak self] placement in
                await self?.restorePlacement(id, to: placement) ?? false
            }
            placements.registerUndo(
                setting: prior, redoing: PartPlacement(part: placed),
                actionName: Self.spareActionName, undoManager: undoManager, write: restore)
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func restorePlacement(_ id: UUID, to placement: PartPlacement) async -> Bool {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            adopt(try await service.place(id, at: placement))
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func registerPresence(
        of id: UUID, setting value: Bool, actionName: String, _ undoManager: UndoManager?
    ) {
        let write: ChangeUndo<Bool>.Write = { [weak self] present in
            await self?.setPresence(of: id, to: present) ?? false
        }
        presence.registerUndo(
            setting: value, redoing: !value, actionName: actionName, undoManager: undoManager,
            write: write)
    }

    // Removes a part, keeping what Undo needs to put it back, or puts a removed part back.
    private func setPresence(of id: UUID, to present: Bool) async -> Bool {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            if present {
                guard let part = removed[id] else { return false }
                adopt(try await service.restore(part))
                removed[id] = nil
            } else {
                // Typing still waiting on the part saves first, so Undo brings it back. A text
                // that did not save stops the removal, so it can be tried again. A text the
                // part does not take, such as a quantity of 0, goes with the part.
                for editor in facts[id]?.editors ?? [] where editor.hasUnsavedChanges {
                    if await !editor.flush(), editor.saveError != nil {
                        saveError =
                            "A field on this part did not save. Try it again before you delete the part."
                        return false
                    }
                }
                let part = try await service.remove(id)
                removed[id] = part
                discard(id)
            }
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func discard(_ id: UUID) {
        parts.removeAll { $0.id == id }
        links[id] = nil
        facts[id] = nil
        if selectedID == id { selectedID = nil }
    }

    private func adopt(_ record: PartRecord) {
        var records = parts
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        apply(PartLibrary(parts: records, links: links))
    }

    private func apply(_ library: PartLibrary) {
        parts = library.parts
        links = library.links
        // A part that went takes its fields with it, so a text it could no longer save never
        // counts as unsaved. A part that comes back gets new fields.
        let kept = Set(library.parts.map(\.id))
        facts = facts.filter { kept.contains($0.key) }
        for part in library.parts {
            if let existing = facts[part.id] {
                existing.refresh(part)
            } else {
                facts[part.id] = PartFacts(part: part, service: service, pause: pause)
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
    @ObservationIgnored private let findSpares: (String) -> [PartRecord]

    init(jobID: UUID, findSpares: @escaping (String) -> [PartRecord]) {
        self.jobID = jobID
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
    // reaches a part added earlier. Redo puts the typing back.
    @ObservationIgnored private var isTypingBurst = false
    @ObservationIgnored private weak var undoManager: UndoManager?

    private func registerTyping(_ undoManager: UndoManager?) {
        guard let undoManager, !isTypingBurst else { return }
        isTypingBurst = true
        registerRestore(PartEntryText(name: text, description: description), undoManager)
    }

    private func registerRestore(_ typed: PartEntryText, _ undoManager: UndoManager) {
        self.undoManager = undoManager
        undoManager.registerUndo(withTarget: self) { [weak undoManager] entry in
            MainActor.assumeIsolated { entry.restore(typed, undoManager: undoManager) }
        }
        undoManager.setActionName(PartEntryWording.typingActionName)
    }

    private func restore(_ typed: PartEntryText, undoManager: UndoManager?) {
        isTypingBurst = false
        if let undoManager {
            registerRestore(PartEntryText(name: text, description: description), undoManager)
        }
        text = typed.name
        description = typed.description
        highlightedID = nil
    }

    private func endTyping() {
        isTypingBurst = false
        undoManager?.removeAllActions(withTarget: self)
    }

    // The parts typed on this line that did not save, in the order they were typed.
    private(set) var unsaved: [PartEntryText] = []

    func keepUnsaved(_ typed: PartEntryText) { unsaved.append(typed) }

    // The first part that did not save, taken off the list while it is tried again.
    func takeUnsaved() -> PartEntryText? { unsaved.isEmpty ? nil : unsaved.removeFirst() }

    func putBackUnsaved(_ typed: PartEntryText) { unsaved.insert(typed, at: 0) }
}
