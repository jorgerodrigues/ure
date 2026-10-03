import AppKit
import SwiftUI

struct WorkshopCommands: Commands {
    let navigation: WorkshopNavigation
    let editing: WorkshopEditing
    let bench: BenchReferenceState
    @FocusedValue(\.allowsWorkshopEditing) private var allowsEditing
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(newRecordTitle, action: createRecord)
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
                .keyboardShortcut(KeyEquivalent(section.shortcut), modifiers: [.command, .option])
                .disabled(allowsEditing != true || editing.isSaving)
            }
            Divider()
            Button("Toggle Reference Pane", action: bench.togglePane)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(allowsEditing != true || editing.jobs.selectedID == nil)
            Button("Open Reference Window", action: openReference)
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(allowsEditing != true || bench.reference == nil)
        }
    }

    private func selectSection(_ section: WorkshopSection) {
        guard allowsEditing == true else { return }
        guard section != navigation.selection else { return }
        editing.requestNavigation { navigation.selection = section }
    }

    private var newRecordTitle: String {
        if navigation.selectedSection == .calibers { return "New Caliber" }
        return "New Watch"
    }

    private var canCreate: Bool {
        guard allowsEditing == true else { return false }
        if editing.isSaving { return false }
        if navigation.selectedSection == .calibers {
            return !editing.calibers.isLoading && editing.calibers.loadError == nil
        }
        return !editing.watches.isLoading && editing.watches.loadError == nil
    }

    private var canSave: Bool {
        guard allowsEditing == true else { return false }
        if editing.isSaving { return false }
        if editing.tasks.draft != nil { return editing.tasks.canSave(jobs: editing.jobs) }
        if editing.documents.draft != nil { return editing.documents.canSave(jobs: editing.jobs) }
        if editing.photos.draft != nil { return editing.photos.canSave(jobs: editing.jobs) }
        if editing.references.draft != nil { return editing.references.canSave }
        if editing.notes.draft != nil { return editing.notes.canSave }
        switch navigation.selectedSection {
        case .watches:
            if editing.jobs.isEditing { return editing.canSaveJob }
            return editing.watches.canSave
        case .calibers: return editing.calibers.canSave
        default: return false
        }
    }

    private func save() {
        guard allowsEditing == true, canSave else { return }
        if editing.tasks.draft != nil {
            editing.tasks.saveCommand()
            return
        }
        if editing.documents.draft != nil {
            editing.documents.saveCommand()
            return
        }
        if editing.photos.draft != nil {
            editing.photos.saveCommand()
            return
        }
        if editing.references.draft != nil {
            editing.references.saveCommand()
            return
        }
        if editing.notes.draft != nil {
            editing.notes.saveCommand()
            return
        }
        switch navigation.selectedSection {
        case .watches:
            if editing.jobs.isEditing {
                editing.saveJobCommand()
            } else {
                editing.watches.saveCommand()
            }
        case .calibers: editing.calibers.saveCommand()
        default: break
        }
    }

    private func createRecord() {
        guard allowsEditing == true else { return }
        let createsCaliber = navigation.selectedSection == .calibers
        editing.requestNavigation {
            if createsCaliber {
                editing.calibers.create()
            } else {
                editing.jobs.close()
                navigation.selection = .watches
                editing.watches.create()
            }
        }
    }

    private func closeWindow() {
        NSApp.keyWindow?.performClose(nil)
    }

    private func openReference() { openWindow(id: "reference") }

    private func canMoveTask(_ destination: JobTaskMove) -> Bool {
        guard allowsEditing == true, navigation.selectedSection == .watches,
            !editing.isSaving, !editing.hasUnsavedChanges,
            let task = editing.tasks.selectedTask, editing.jobs.selectedID == task.jobID,
            !editing.jobs.isEditing
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
