import SwiftUI

@main
struct UreApp: App {
    @NSApplicationDelegateAdaptor(WorkshopApplicationDelegate.self) private var applicationDelegate
    @State private var restore: RestoreState

    init() {
        let configuration = AppConfiguration.current
        #if DEBUG
            let dependencies = LibraryTestSeed.dependencies(
                environment: ProcessInfo.processInfo.environment)
        #else
            let dependencies = LibraryDependencies()
        #endif
        let coordinator = LibraryCoordinator(
            root: configuration.libraryRoot, dependencies: dependencies)
        let restore = RestoreState(
            library: LibraryState(coordinator: coordinator), configuration: configuration)
        _restore = State(initialValue: restore)
        applicationDelegate.restore = restore
    }

    var body: some Scene {
        Window("Ure", id: "workshop") {
            LibraryRootView()
                .id(restore.session.id)
                .environment(restore.session.navigation)
                .environment(restore.library)
                .environment(restore.session.watches)
                .environment(restore.session.calibers)
                .environment(restore.session.jobs)
                .environment(restore.session.search)
                .environment(restore.session.workshop)
                .environment(restore.session.partsOverview)
                .environment(restore.session.notes)
                .environment(restore.session.tasks)
                .environment(restore.session.parts)
                .environment(restore.session.references)
                .environment(restore.session.photos)
                .environment(restore.session.documents)
                .environment(restore.session.editing)
                .environment(restore.session.bench)
                .focusedSceneValue(\.allowsWorkshopEditing, !restore.isActivating)
                .frame(minWidth: 1000, minHeight: 650)
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            WorkshopCommands(
                navigation: restore.session.navigation, editing: restore.session.editing,
                bench: restore.session.bench, search: restore.session.search)
        }

        Window("Reference", id: "reference") {
            Group {
                if restore.isActivating {
                    ProgressView("Restoring library…")
                } else {
                    ReferenceWindowView(bench: restore.session.bench)
                        .id(restore.session.id)
                }
            }
            .frame(minWidth: 420, minHeight: 650)
        }
        .defaultSize(width: 620, height: 720)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(restore.library)
                .environment(restore.backup)
                .environment(restore)
        }
    }
}
