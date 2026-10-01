import SwiftUI

@main
struct UreApp: App {
    @State private var navigation = WorkshopNavigation(configuration: .current)

    var body: some Scene {
        Window("Ure", id: "workshop") {
            WorkshopView()
                .environment(navigation)
                .frame(minWidth: 1000, minHeight: 650)
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            WorkshopCommands(navigation: navigation)
        }

        Settings {
            SettingsView()
        }
    }
}
