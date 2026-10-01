import SwiftUI

struct WorkshopCommands: Commands {
    let navigation: WorkshopNavigation

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()

            ForEach(WorkshopSection.allCases) { section in
                Button(section.title) {
                    navigation.selection = section
                }
                .keyboardShortcut(KeyEquivalent(section.shortcut), modifiers: [.command, .option])
            }
        }
    }
}
