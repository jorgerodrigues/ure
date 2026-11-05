import SwiftUI

// The folded Archived section at the end of a list: its title, how many records it holds, and
// a chevron that points down while it is open. Values from the "4 Watch" and "4b Archived
// watch" artboards on the Paper page "Rework · Simple".
struct ArchivedSectionHeader: View {
    let count: Int
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Text("Archived")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(count)")
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 9)
                }
                .font(.system(size: ArchivedLayout.headerSize))
                .foregroundStyle(.secondary)
                .padding(.top, ArchivedLayout.headerTop)
                .padding(.bottom, ArchivedLayout.headerBottom)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, ArchivedLayout.headerGap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Archived")
        .accessibilityValue(isExpanded ? "\(count), open" : "\(count), folded")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, toggle)
    }

    private func toggle() { isExpanded.toggle() }
}

// The line under an archived record's name, such as "Archived 3 November", with a note on what
// archiving does.
struct ArchivedPill: View {
    let archivedAt: Date
    let note: String

    var body: some View {
        HStack(spacing: ArchivedLayout.pillSpacing) {
            Label {
                Text("Archived \(PageLayout.day(archivedAt))")
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: "archivebox")
                    .font(.system(size: 10, weight: .semibold))
            }
            .labelStyle(ArchivedPillLabelStyle())
            .padding(.leading, 8)
            .padding(.trailing, 9)
            .frame(height: ArchivedLayout.pillHeight)
            .background(Color(nsColor: .quaternarySystemFill), in: Capsule())
            Text(note)
        }
        .font(.system(size: PageLayout.pillTextSize))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct ArchivedPillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

// When a list row's record was archived, such as "3 Nov" this year or "June 2025" before.
enum ArchivedDate {
    static func short(_ date: Date, now: Date = .now) -> String {
        if Calendar.current.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.month(.wide).year())
    }
}

private enum ArchivedLayout {
    static let headerSize: CGFloat = 11
    static let headerGap: CGFloat = 10
    static let headerTop: CGFloat = 18
    static let headerBottom: CGFloat = 6
    static let pillHeight: CGFloat = 22
    static let pillSpacing: CGFloat = 10
}
