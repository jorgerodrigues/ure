import SwiftUI

struct WorkshopView: View {
    @Environment(WorkshopNavigation.self) private var navigation

    var body: some View {
        NavigationSplitView {
            WorkshopSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } content: {
            WorkshopSectionView(section: navigation.selectedSection)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
        } detail: {
            ContentUnavailableView(
                "Select a record",
                systemImage: navigation.selectedSection.symbol,
                description: Text("Choose an item to view its details.")
            )
        }
    }
}
