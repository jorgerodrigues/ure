import SwiftUI

// Where a record section sits. A form section is a row group in the grouped forms the watch
// and job pages still use. A page section sits under a heading on a page you write on.
enum RecordSectionStyle {
    case form
    case page
}

// A section heading on a page you write on: a 17 pt bold title, and on the right a quiet
// count or date, such as "2 watches" or "Edited 15 October".
struct PageSectionHeading: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: PageLayout.headingSize, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            if let detail {
                Text(detail)
                    .font(.system(size: PageLayout.detailSize))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// Values from the "5 Caliber" artboard on the Paper page "Rework · Simple".
enum PageLayout {
    static let headingSize: CGFloat = 17
    static let detailSize: CGFloat = 13
    static let sectionSpacing: CGFloat = 40
    static let headingSpacing: CGFloat = 12
    static let topPadding: CGFloat = 40
    static let sidePadding: CGFloat = 56
    static let bottomPadding: CGFloat = 64

    // A date as a page shows it, such as "15 October", with the year when it is not this year.
    static func day(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let style = Date.FormatStyle.dateTime.day().month(.wide)
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(style)
        }
        return date.formatted(style.year())
    }
}
