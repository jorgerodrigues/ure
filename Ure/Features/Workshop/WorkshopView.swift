import SwiftUI

struct WorkshopView: View {
    @Environment(WorkshopNavigation.self) private var navigation
    @Environment(WatchState.self) private var watches

    var body: some View {
        @Bindable var watches = watches

        NavigationSplitView {
            WorkshopSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } content: {
            Group {
                if navigation.selectedSection == .watches {
                    WatchListView()
                } else {
                    WorkshopSectionView(section: navigation.selectedSection)
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
        } detail: {
            if navigation.selectedSection == .watches {
                WatchDetailView()
            } else {
                ContentUnavailableView(
                    "Select a record",
                    systemImage: navigation.selectedSection.symbol,
                    description: Text("Choose an item to view its details.")
                )
            }
        }
        .task(watches.observe)
        .background(WatchWindowGuard(watches: watches))
        .alert("Save changes to this watch?", isPresented: $watches.showsUnsavedChanges) {
            Button("Save", action: watches.saveAndContinueCommand)
            Button("Discard", role: .destructive, action: watches.discardAndContinue)
            Button("Stay", role: .cancel, action: watches.stay)
        } message: {
            Text("Your changes have not been saved.")
        }
    }
}
