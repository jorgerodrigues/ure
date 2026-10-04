import SwiftUI

struct WorkshopSidebarRow: View {
    let section: WorkshopSection
    let isSelected: Bool

    var body: some View {
        Label {
            Text(section.title)
                .fontWeight(isSelected ? .semibold : .regular)
        } icon: {
            Image(systemName: section.symbol)
                .foregroundStyle(.tint)
                .frame(width: UreLayout.sidebarIconWidth)
        }
        .font(.body)
    }
}
