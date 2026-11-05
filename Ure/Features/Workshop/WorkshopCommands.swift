import AppKit
import SwiftUI

struct WorkshopCommands: Commands {
    let navigation: WorkshopNavigation
    let editing: WorkshopEditing
    let bench: BenchReferenceState
    let search: SearchState
    @FocusedValue(\.allowsWorkshopEditing) private var allowsEditing
    @FocusedValue(\.recordMenuActions) private var recordActions
    @FocusedValue(\.recordBackAction) private var recordBackAction
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(NewRecord.title(in: navigation.selectedSection), action: createRecord)
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!canCreate)
        }
        CommandGroup(after: .newItem) {
            Button("Close", action: closeWindow)
                .keyboardShortcut("w", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save", action: save)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSave)
            Button("Cancel", action: editing.cancelDraft)
                .keyboardShortcut(".", modifiers: .command)
                .disabled(allowsEditing != true || !editing.canCancelDraft)
        }
        CommandGroup(after: .pasteboard) {
            Button("Insert Today’s Date", action: insertToday)
                .keyboardShortcut("d", modifiers: .command)
                .disabled(allowsEditing != true || !editing.notes.isEditing)
        }
        CommandGroup(before: .textEditing) {
            Button("Search", action: focusSearch)
                .keyboardShortcut("f", modifiers: .command)
                .disabled(allowsEditing != true)
        }
        CommandGroup(after: .textEditing) {
            Button("Search Library", action: search.present)
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(allowsEditing != true)
            Button("Close Search", action: search.close)
                .disabled(allowsEditing != true || !search.isPresented)
        }
        CommandGroup(after: .importExport) {
            Button("Export Original…", action: exportOriginal)
                .disabled(!canUseRecordActions || recordActions?.exportOriginal == nil)
        }
        CommandMenu("Record") {
            Button(recordActions?.editTitle ?? "Edit", action: editRecord)
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!canUseRecordActions || recordActions?.edit == nil)
            Button(recordActions?.removeTitle ?? "Remove", role: .destructive, action: removeRecord)
                .disabled(!canUseRecordActions || recordActions?.remove == nil)
            Button(recordBackAction?.title ?? "Back", action: backToOwner)
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!canUseRecordActions || recordBackAction == nil)
            Divider()
            Button(archiveTitle, action: toggleArchive)
                .disabled(!canArchive)
        }
        CommandMenu("Task") {
            Button("Move up", action: moveTaskUp)
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!canMoveTask(.up))
            Button("Move down", action: moveTaskDown)
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!canMoveTask(.down))
        }
        CommandGroup(after: .sidebar) {
            Divider()

            ForEach(WorkshopSection.allCases) { section in
                Button(section.title) {
                    selectSection(section)
                }
                .keyboardShortcut(KeyEquivalent(section.shortcut), modifiers: .command)
                .disabled(allowsEditing != true || editing.isSaving)
            }
            Divider()
            BenchPinMenu(bench: bench)
                .disabled(allowsEditing != true || editing.jobs.selectedID == nil)
            Button("Toggle Reference Pane", action: bench.togglePane)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(allowsEditing != true || editing.jobs.selectedID == nil)
            Button("Open Reference Window", action: openReference)
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(allowsEditing != true || bench.reference == nil)
        }
    }

    private var archiveTitle: String {
        if navigation.selectedSection == .calibers {
            if editing.calibers.selectedCaliber?.archivedAt != nil { return "Unarchive Caliber" }
            return "Archive Caliber"
        }
        if editing.watches.selectedWatch?.archivedAt != nil { return "Unarchive Watch" }
        return "Archive Watch"
    }
    // Archiving has no rules: any watch can be archived, even one with an open job.
    private var canArchive: Bool {
        guard allowsEditing == true, !editing.isSaving, !editing.hasUnsavedChanges else {
            return false
        }
        switch navigation.selectedSection {
        case .calibers: return editing.calibers.selectedCaliber != nil
        case .watches: return editing.watches.selectedWatch != nil
        default: return false
        }
    }
    private func toggleArchive() {
        guard canArchive else { return }
        let undoManager = NSApp.keyWindow?.undoManager
        if navigation.selectedSection == .calibers {
            editing.requestNavigation {
                editing.calibers.toggleArchiveCommand(undoManager: undoManager)
            }
        } else {
            editing.requestNavigation {
                editing.watches.toggleArchiveCommand(undoManager: undoManager)
            }
        }
    }

    private func selectSection(_ section: WorkshopSection) {
        guard allowsEditing == true else { return }
        guard search.isPresented || section != navigation.selection else { return }
        editing.requestNavigation {
            search.close(); navigation.selection = section
        }
    }

    private var canCreate: Bool {
        allowsEditing == true && NewRecord.canMake(in: navigation.selectedSection, editing: editing)
    }

    // ⌘F puts the cursor in the toolbar's search field, from every section.
    private func focusSearch() {
        guard allowsEditing == true else { return }
        navigation.focusSearch()
    }

    // Only the task and part editors still save with ⌘S.
    private var canSave: Bool {
        guard allowsEditing == true else { return false }
        if editing.isSaving { return false }
        if editing.parts.draft != nil { return editing.parts.canSave(jobs: editing.jobs) }
        if editing.tasks.draft != nil { return editing.tasks.canSave(jobs: editing.jobs) }
        return false
    }

    private func save() {
        guard allowsEditing == true, canSave else { return }
        if editing.parts.draft != nil {
            editing.parts.saveCommand()
        } else {
            editing.tasks.saveCommand()
        }
    }

    private func createRecord() {
        guard allowsEditing == true else { return }
        NewRecord.make(
            in: navigation.selectedSection, editing: editing, navigation: navigation,
            search: search)
    }

    private func insertToday() {
        NSApp.sendAction(#selector(NotesEditingView.insertToday(_:)), to: nil, from: nil)
    }

    private func closeWindow() {
        NSApp.keyWindow?.performClose(nil)
    }

    private func editRecord() { if canUseRecordActions { recordActions?.edit?() } }
    private func removeRecord() { if canUseRecordActions { recordActions?.remove?() } }
    private func exportOriginal() { if canUseRecordActions { recordActions?.exportOriginal?() } }
    private func backToOwner() { if canUseRecordActions { recordBackAction?.action() } }
    private var canUseRecordActions: Bool {
        allowsEditing == true && !editing.isSaving && !editing.isNavigationPending
    }

    private func openReference() { openWindow(id: "reference") }

    private func canMoveTask(_ destination: JobTaskMove) -> Bool {
        guard allowsEditing == true,
            navigation.selectedSection != .calibers,
            !editing.isSaving, !editing.hasUnsavedChanges,
            let task = editing.tasks.selectedTask, editing.jobs.selectedID == task.jobID
        else { return false }
        return editing.tasks.canMove(task.id, for: task.jobID, to: destination, jobs: editing.jobs)
    }

    private func moveTaskUp() { moveTask(.up) }
    private func moveTaskDown() { moveTask(.down) }

    private func moveTask(_ destination: JobTaskMove) {
        guard canMoveTask(destination), let task = editing.tasks.selectedTask else { return }
        editing.tasks.moveCommand(task.id, for: task.jobID, to: destination, jobs: editing.jobs)
    }
}
