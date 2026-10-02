import SwiftUI

struct WorkshopCommands: Commands {
    let navigation: WorkshopNavigation
    let watches: WatchState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Watch", action: createWatch)
                .keyboardShortcut("n", modifiers: .command)
                .disabled(watches.isLoading || watches.isSaving || watches.loadError != nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save", action: watches.saveCommand)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!watches.canSave || navigation.selectedSection != .watches)
        }
        CommandGroup(after: .sidebar) {
            Divider()

            ForEach(WorkshopSection.allCases) { section in
                Button(section.title) {
                    selectSection(section)
                }
                .keyboardShortcut(KeyEquivalent(section.shortcut), modifiers: [.command, .option])
                .disabled(watches.isSaving)
            }
        }
    }

    private func selectSection(_ section: WorkshopSection) {
        guard section != navigation.selection else { return }
        watches.requestNavigation { navigation.selection = section }
    }

    private func createWatch() {
        watches.requestNavigation {
            navigation.selection = .watches
            watches.create()
        }
    }
}
