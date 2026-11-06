import SwiftUI

// What ⌘N and the toolbar's New button make in each section. Both use the same name, such as
// "New Job", so the menu and the toolbar always say the same thing.
enum NewRecord {
    static func title(in section: WorkshopSection) -> String {
        switch section {
        case .jobs: JobService.newTitle
        case .parts: PartService.newName
        case .calibers: "New Caliber"
        case .watches: "New Watch"
        }
    }

    static func canMake(in section: WorkshopSection, editing: WorkshopEditing) -> Bool {
        guard !editing.isSaving else { return false }
        switch section {
        case .jobs: return !editing.jobs.isLoading && editing.jobs.loadError == nil
        case .parts: return !editing.parts.isLoading && editing.parts.loadError == nil
        case .calibers: return !editing.calibers.isLoading && editing.calibers.loadError == nil
        case .watches:
            return !editing.watches.isLoading && editing.watches.loadError == nil
        }
    }

    // A new job starts without a watch, with the cursor in its title. A new part in Parts is a
    // spare in the drawer. A new watch opens in Watches and a new caliber in Calibers. Each
    // puts the cursor in its name.
    static func make(in section: WorkshopSection, editing: WorkshopEditing, search: SearchState) {
        guard canMake(in: section, editing: editing) else { return }
        editing.requestNavigation {
            search.close()
            editing.closeChildren()
            switch section {
            case .jobs:
                editing.watches.select(nil)
                editing.jobs.createCommand()
            case .parts:
                editing.parts.makeSpareCommand()
            case .calibers:
                editing.calibers.createCommand()
            case .watches:
                editing.jobs.close()
                editing.watches.createCommand()
            }
        }
    }
}

// The toolbar's New button for the selected section, such as "New Job".
struct NewRecordButton: View {
    @Environment(WorkshopEditing.self) private var editing
    @Environment(SearchState.self) private var search
    let section: WorkshopSection

    var body: some View {
        Button(NewRecord.title(in: section), systemImage: "plus", action: make)
            .labelStyle(.iconOnly)
            .help("\(NewRecord.title(in: section)) (⌘N)")
            .disabled(!NewRecord.canMake(in: section, editing: editing))
            .accessibilityIdentifier("newRecord")
    }

    private func make() {
        NewRecord.make(in: section, editing: editing, search: search)
    }
}
