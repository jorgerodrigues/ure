import SwiftUI

@main
struct UreApp: App {
    @NSApplicationDelegateAdaptor(WorkshopApplicationDelegate.self) private var applicationDelegate
    @State private var navigation: WorkshopNavigation
    @State private var library: LibraryState
    @State private var watches: WatchState
    @State private var calibers: CaliberState
    @State private var jobs: JobState
    @State private var editing: WorkshopEditing

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
        let calibers = CaliberState(service: CaliberService(coordinator: coordinator))
        let jobs = JobState(service: JobService(coordinator: coordinator))
        let editing = WorkshopEditing(watches: watches, calibers: calibers, jobs: jobs)
        _library = State(initialValue: LibraryState(coordinator: coordinator))
        _watches = State(initialValue: watches)
        _calibers = State(initialValue: calibers)
        _jobs = State(initialValue: jobs)
        _editing = State(initialValue: editing)
        applicationDelegate.editing = editing
    }

    var body: some Scene {
        Window("Ure", id: "workshop") {
            LibraryRootView()
                .environment(navigation)
                .environment(library)
                .environment(watches)
                .environment(calibers)
                .environment(jobs)
                .environment(editing)
                .frame(minWidth: 1000, minHeight: 650)
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            WorkshopCommands(navigation: navigation, editing: editing)
        }

        Settings {
            SettingsView()
                .environment(library)
        }
    }
}
