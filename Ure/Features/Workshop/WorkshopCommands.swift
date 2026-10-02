import AppKit
import SwiftUI

struct WorkshopCommands: Commands {
    let navigation: WorkshopNavigation
    let editing: WorkshopEditing

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
        CommandGroup(after: .sidebar) {
            Divider()

            ForEach(WorkshopSection.allCases) { section in
                Button(section.title) {
                    selectSection(section)
                }
                .keyboardShortcut(KeyEquivalent(section.shortcut), modifiers: [.command, .option])
                .disabled(editing.isSaving)
            }
        }
    }

    private func selectSection(_ section: WorkshopSection) {
        guard section != navigation.selection else { return }
        editing.requestNavigation { navigation.selection = section }
    }

    private var newRecordTitle: String {
        if navigation.selectedSection == .calibers { return "New Caliber" }
        return "New Watch"
    }

    private var canCreate: Bool {
        if editing.isSaving { return false }
        if navigation.selectedSection == .calibers {
            return !editing.calibers.isLoading && editing.calibers.loadError == nil
        }
        return !editing.watches.isLoading && editing.watches.loadError == nil
    }

    private var canSave: Bool {
        if editing.isSaving { return false }
        switch navigation.selectedSection {
        case .watches:
            if editing.jobs.isEditing { return editing.jobs.canSave }
            return editing.watches.canSave
        case .calibers: return editing.calibers.canSave
        default: return false
        }
    }

    private func save() {
        switch navigation.selectedSection {
        case .watches:
            if editing.jobs.isEditing {
                editing.jobs.saveCommand()
            } else {
                editing.watches.saveCommand()
            }
        case .calibers: editing.calibers.saveCommand()
        default: break
        }
    }

    private func createRecord() {
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
}
