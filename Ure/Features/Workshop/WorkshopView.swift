import SwiftUI

struct WorkshopView: View {
    @Environment(WorkshopNavigation.self) private var navigation
    @Environment(WatchState.self) private var watches
    @Environment(CaliberState.self) private var calibers
    @Environment(WorkshopEditing.self) private var editing

    var body: some View {
        @Bindable var editing = editing

        NavigationSplitView {
            WorkshopSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } content: {
            Group {
                if navigation.selectedSection == .watches {
                    WatchListView()
                } else if navigation.selectedSection == .calibers {
                    CaliberListView()
                } else {
                    WorkshopSectionView(section: navigation.selectedSection)
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
        } detail: {
            if navigation.selectedSection == .watches {
                WatchDetailView()
            } else if navigation.selectedSection == .calibers {
                CaliberDetailView()
            } else {
                ContentUnavailableView(
                    "Select a record",
                    systemImage: navigation.selectedSection.symbol,
                    description: Text("Choose an item to view its details.")
                )
            }
        }
        .task(watches.observe)
        .task(calibers.observe)
        .background(WorkshopWindowGuard(editing: editing))
        .alert(editing.unsavedChangesTitle, isPresented: $editing.showsUnsavedChanges) {
            Button("Save", action: editing.saveAndContinueCommand)
            Button("Discard", role: .destructive, action: editing.discardAndContinue)
            Button("Stay", role: .cancel, action: editing.stay)
        } message: {
            Text("Your changes have not been saved.")
        }
    }
}
