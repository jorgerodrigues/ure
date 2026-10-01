import SwiftUI

struct WorkshopSidebar: View {
    @Environment(WorkshopNavigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation

        List(WorkshopSection.allCases, selection: $navigation.selection) { section in
            Label(section.title, systemImage: section.symbol)
                .tag(section)
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Workshop sections")
    }
}
