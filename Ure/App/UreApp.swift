import SwiftUI

@main
struct UreApp: App {
    @State private var navigation: WorkshopNavigation
    @State private var library: LibraryState

    init() {
        let configuration = AppConfiguration.current
        #if DEBUG
            let dependencies = LibraryTestSeed.dependencies(
                environment: ProcessInfo.processInfo.environment)
        #else
            let dependencies = LibraryDependencies()
        #endif
        _navigation = State(initialValue: WorkshopNavigation(configuration: configuration))
        _library = State(
            initialValue: LibraryState(
                coordinator: LibraryCoordinator(
                    root: configuration.libraryRoot, dependencies: dependencies))
        )
    }

    var body: some Scene {
        Window("Ure", id: "workshop") {
            LibraryRootView()
                .environment(navigation)
                .environment(library)
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
                .environment(library)
        }
    }
}
