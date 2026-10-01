import SwiftUI

struct WorkshopSectionView: View {
    let section: WorkshopSection

    var body: some View {
        ContentUnavailableView(
            section.emptyTitle,
            systemImage: section.symbol,
            description: Text(section.emptyDescription)
        )
        .navigationTitle(section.title)
    }
}
