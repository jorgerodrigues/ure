import AppKit
import SwiftUI

struct WorkshopCommands: Commands {
    let navigation: WorkshopNavigation
    let editing: WorkshopEditing
    let bench: BenchReferenceState
    let search: SearchState
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
        CommandGroup(after: .textEditing) {
            Button("Search Library", action: search.present)
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(allowsEditing != true)
        }
        CommandMenu("Record") {
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

    private var archiveTitle: String {
        if navigation.selectedSection == .calibers
            || (navigation.selectedSection == .archive
                && editing.archive.isShowingCaliber(editing: editing))
        {
            if editing.calibers.selectedCaliber?.archivedAt != nil { return "Unarchive Caliber" }
            return "Archive Caliber"
        }
        if editing.watches.selectedWatch?.archivedAt != nil { return "Unarchive Watch" }
        return "Archive Watch"
    }
    private var canArchive: Bool {
        guard allowsEditing == true, !editing.isSaving, !editing.hasUnsavedChanges else {
            return false
        }
        if navigation.selectedSection == .calibers
            || (navigation.selectedSection == .archive
                && editing.archive.isShowingCaliber(editing: editing))
        {
            return editing.calibers.draft == nil && editing.calibers.selectedCaliber != nil
        }
        guard navigation.selectedSection == .watches || navigation.selectedSection == .archive,
            let watch = editing.watches.selectedWatch, editing.watches.draft == nil,
            !editing.jobs.isLoading, editing.jobs.loadError == nil
        else { return false }
        return watch.archivedAt != nil || editing.jobs.openJob(for: watch.id) == nil
    }
    private func toggleArchive() {
        guard canArchive else { return }
        if navigation.selectedSection == .calibers
            || (navigation.selectedSection == .archive
                && editing.archive.isShowingCaliber(editing: editing))
        {
            editing.requestNavigation(editing.calibers.toggleArchiveCommand)
        } else {
            editing.requestNavigation(editing.watches.toggleArchiveCommand)
        }
    }

    private func selectSection(_ section: WorkshopSection) {
        guard allowsEditing == true else { return }
        guard search.isPresented || section != navigation.selection else { return }
        editing.requestNavigation {
            search.close(); navigation.selection = section
        }
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
        if editing.parts.draft != nil { return editing.parts.canSave(jobs: editing.jobs) }
        if editing.tasks.draft != nil { return editing.tasks.canSave(jobs: editing.jobs) }
        if editing.documents.draft != nil {
            guard let owner = editing.documents.owner else { return false }
            return editing.documents.canSave(jobs: editing.jobs) && editing.canWrite(owner)
        }
        if editing.photos.draft != nil {
            guard let owner = editing.photos.owner else { return false }
            return editing.photos.canSave(jobs: editing.jobs) && editing.canWrite(owner)
        }
        if editing.references.draft != nil {
            guard let owner = editing.references.owner else { return false }
            return editing.references.canSave && editing.canWrite(owner)
        }
        if editing.notes.draft != nil {
            guard let owner = editing.notes.owner else { return false }
            return editing.notes.canSave && editing.canWrite(owner)
        }
        switch navigation.selectedSection {
        case .workshop, .watches, .parts:
            if editing.jobs.isEditing { return editing.canSaveJob }
            return editing.watches.canSave
        case .calibers: return editing.calibers.canSave
        default: return false
        }
    }

    private func save() {
        guard allowsEditing == true, canSave else { return }
        if editing.parts.draft != nil {
            editing.parts.saveCommand()
            return
        }
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
        case .workshop, .watches, .parts:
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
        guard allowsEditing == true,
            navigation.selectedSection == .watches || navigation.selectedSection == .workshop
                || navigation.selectedSection == .parts,
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
