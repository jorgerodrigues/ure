import SwiftUI

// A part's state as a small pill, like a job's. A part on its way has the accent colour and a
// dot. A fitted part is grey with a tick. On the part page the pill is the state pop-up, with
// the pop-up's arrows after the state.
struct PartStagePill: View {
    let stage: PartStage
    var showsIndicator = false

    var body: some View {
        HStack(spacing: isOnItsWay ? PartPillLayout.spacing : PartPillLayout.tickSpacing) {
            if isOnItsWay {
                Circle().fill(Color.accentColor)
                    .frame(width: PartPillLayout.dotSize, height: PartPillLayout.dotSize)
            } else {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
            }
            Text(stage.rawValue)
                .font(.system(size: PageLayout.pillTextSize, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            if showsIndicator {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
        }
        .foregroundStyle(isOnItsWay ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        .padding(.leading, PartPillLayout.leading)
        .padding(
            .trailing, showsIndicator ? PartPillLayout.indicatorTrailing : PartPillLayout.leading
        )
        .frame(height: PartPillLayout.height)
        .background(background, in: Capsule())
    }

    private var isOnItsWay: Bool { stage != .fitted }

    private var background: Color {
        if isOnItsWay { return Color.accentColor.opacity(0.1) }
        return Color(nsColor: .quaternarySystemFill)
    }
}

// The same values as a job's pill on the "2 Job" artboard.
private enum PartPillLayout {
    static let height: CGFloat = 22
    static let leading: CGFloat = 9
    static let indicatorTrailing: CGFloat = 8
    static let spacing: CGFloat = 6
    static let tickSpacing: CGFloat = 4
    static let dotSize: CGFloat = 6
}

// How a part words its state's day, such as "Ordered 3 Nov" on its line and "Ordered 3
// November" on its page. A part that is needed has no day.
enum PartWording {
    static func date(of part: PartRecord) -> Date? {
        switch part.stage {
        case .needed: nil
        case .ordered: part.orderedAt
        case .inHand: part.inHandAt
        case .fitted: part.fittedAt
        }
    }

    // The short day on a part's line, such as "3 Nov".
    static func shortDay(of part: PartRecord, now: Date = .now) -> String? {
        guard let date = date(of: part) else { return nil }
        let calendar = Calendar.current
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(style)
        }
        return date.formatted(style.year())
    }

    // Every day the part has reached, such as "Ordered 3 November · In hand 5 November".
    static func days(of part: PartRecord, now: Date = .now) -> String? {
        let days = [
            part.orderedAt.map { "Ordered \(PageLayout.day($0, now: now))" },
            part.inHandAt.map { "In hand \(PageLayout.day($0, now: now))" },
            part.fittedAt.map { "Fitted \(PageLayout.day($0, now: now))" },
        ].compactMap { $0 }
        return days.isEmpty ? nil : days.joined(separator: " · ")
    }

    // What a click on the state does, such as "Move to Ordered".
    static func advanceTitle(of stage: PartStage) -> String? {
        stage.next.map { "Move to \($0.rawValue)" }
    }
}
