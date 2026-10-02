import SwiftUI

@main
struct UreApp: App {
    @NSApplicationDelegateAdaptor(WatchApplicationDelegate.self) private var applicationDelegate
    @State private var navigation: WorkshopNavigation
    @State private var library: LibraryState
    @State private var watches: WatchState

    init() {
        let configuration = AppConfiguration.current
        #if DEBUG
            let dependencies = LibraryTestSeed.dependencies(
                environment: ProcessInfo.processInfo.environment)
        #else
            let dependencies = LibraryDependencies()
        #endif
        _navigation = State(initialValue: WorkshopNavigation(configuration: configuration))
        let coordinator = LibraryCoordinator(
            root: configuration.libraryRoot, dependencies: dependencies)
        let watches = WatchState(service: WatchService(coordinator: coordinator))
        _library = State(initialValue: LibraryState(coordinator: coordinator))
        _watches = State(initialValue: watches)
        applicationDelegate.watches = watches
    }

    var body: some Scene {
        Window("Ure", id: "workshop") {
            LibraryRootView()
                .environment(navigation)
                .environment(library)
                .environment(watches)
                .frame(minWidth: 1000, minHeight: 650)
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            WorkshopCommands(navigation: navigation, watches: watches)
        }

        Settings {
            SettingsView()
                .environment(library)
        }
    }
}
