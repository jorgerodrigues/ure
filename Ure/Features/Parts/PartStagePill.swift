import SwiftUI

// A part's state as a pill, as on the "2 Job" and "7 Typing" artboards. Each state reads a step
// further along: Needed is an outline, Ordered a soft accent fill, In hand the accent colour,
// and Fitted grey with a tick. On a part's line every pill has the same width, so the names line
// up. On the part page the pill is the state pop-up, with the pop-up's arrows after the state.
struct PartStagePill: View {
    let stage: PartStage
    var showsIndicator = false

    var body: some View {
        HStack(spacing: PartPillLayout.spacing) {
            if stage == .fitted {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
            }
            Text(stage.rawValue)
                .font(.system(size: PageLayout.pillTextSize, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            if showsIndicator {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(foreground)
        .padding(.leading, showsIndicator ? PartPillLayout.leading : 0)
        .padding(.trailing, showsIndicator ? PartPillLayout.indicatorTrailing : 0)
        .frame(width: showsIndicator ? nil : PartPillLayout.width, height: PartPillLayout.height)
        .background(background, in: Capsule())
        .overlay {
            if stage == .needed {
                Capsule().strokeBorder(
                    Color.primary.opacity(PartPillLayout.outlineOpacity), lineWidth: 1)
            }
        }
    }

    private var foreground: AnyShapeStyle {
        switch stage {
        case .needed: AnyShapeStyle(.primary)
        case .ordered: AnyShapeStyle(Color.accentColor)
        case .inHand: AnyShapeStyle(Color.white)
        case .fitted: AnyShapeStyle(.secondary)
        }
    }

    private var background: Color {
        switch stage {
        case .needed: .clear
        case .ordered: Color.accentColor.opacity(PartPillLayout.orderedOpacity)
        case .inHand: .accentColor
        case .fitted: Color(nsColor: .quaternarySystemFill)
        }
    }
}

// Values from the "2 Job", "3 Parts" and "7 Typing" artboards on the Paper page "Rework ·
// Simple".
enum PartPillLayout {
    static let width: CGFloat = 76
    static let height: CGFloat = 22
    static let leading: CGFloat = 10
    static let indicatorTrailing: CGFloat = 8
    static let spacing: CGFloat = 4
    static let outlineOpacity: Double = 0.22
    static let orderedOpacity: Double = 0.12
}

// How a part words its state's day, such as "ordered 30 Oct" on its line and "Ordered 30
// October" on its page. A part that is needed has no day yet.
enum PartWording {
    static func date(of part: PartRecord) -> Date? {
        switch part.stage {
        case .needed: nil
        case .ordered: part.orderedAt
        case .inHand: part.inHandAt
        case .fitted: part.fittedAt
        }
    }

    // A short day, such as "30 Oct", with the year when it is not this year.
    static func shortDay(_ date: Date, now: Date = .now) -> String {
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        if Calendar.current.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(style)
        }
        return date.formatted(style.year())
    }

    // The day of the part's state, such as "ordered 30 Oct", "arrived 2 Nov" or "fitted 4 Nov".
    static func stateDay(of part: PartRecord, now: Date = .now) -> String? {
        guard let date = date(of: part) else { return nil }
        let day = shortDay(date, now: now)
        switch part.stage {
        case .needed: return nil
        case .ordered: return "ordered \(day)"
        case .inHand: return "arrived \(day)"
        case .fitted: return "fitted \(day)"
        }
    }

    // The line under a part's name on its job: the first line of its description and the day of
    // its state, such as "GR 3800 · ordered 30 Oct". Nil when it has neither.
    static func detail(of part: PartRecord, now: Date = .now) -> String? {
        let parts = [firstLine(of: part.description), stateDay(of: part, now: now)]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func firstLine(of text: String?) -> String? {
        guard let line = text?.split(separator: "\n").first else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // When the part was added and every day it reached since, such as "Added 14 October ·
    // Ordered 15 October".
    static func days(of part: PartRecord, now: Date = .now) -> String {
        [
            "Added \(PageLayout.day(part.createdAt, now: now))",
            part.orderedAt.map { "Ordered \(PageLayout.day($0, now: now))" },
            part.inHandAt.map { "In hand \(PageLayout.day($0, now: now))" },
            part.fittedAt.map { "Fitted \(PageLayout.day($0, now: now))" },
        ].compactMap { $0 }.joined(separator: " · ")
    }

    // What a click on the state does, such as "Move to Ordered".
    static func advanceTitle(of stage: PartStage) -> String? {
        stage.next.map { "Move to \($0.rawValue)" }
    }
}
