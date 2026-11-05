import SwiftUI

struct WorkshopSidebarRow: View {
    let section: WorkshopSection
    let isSelected: Bool
    let count: Int?

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
        .badge(count ?? 0)
        .accessibilityValue(count.map { "\($0)" } ?? "")
        .accessibilityIdentifier("sidebar-\(section.rawValue)")
    }
}
