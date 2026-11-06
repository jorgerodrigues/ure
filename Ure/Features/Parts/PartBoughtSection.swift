import SwiftUI

// What was bought for a part, as on the "3b Part, after Buy" artboard: the supplier, the price
// and the shipping in the shop's currency, and what you paid in your home currency, with the
// days the part reached. The options it was not bought from are kept under a line you can open.
struct PartBoughtSection: View {
    @Environment(PartState.self) private var parts
    @Environment(MoneyState.self) private var money
    let part: PartRecord
    let purchase: PartPurchase
    let isEditable: Bool
    @State private var showsOtherOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: BoughtLayout.spacing) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bought")
                    .font(.system(size: PageLayout.headingSize, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                if let url = purchase.url {
                    Button(action: { parts.openLink(url) }) {
                        HStack(spacing: 5) {
                            Text("Open listing")
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 11))
                        }
                        .font(.system(size: PageLayout.detailSize))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("openBoughtListing")
                }
            }
            HStack(alignment: .top, spacing: PageLayout.factColumnSpacing) {
                BoughtValue(label: "Supplier", value: purchase.supplier ?? "Not given")
                BoughtValue(label: "Price", value: purchase.price.formatted())
                BoughtValue(label: "Shipping", value: shipping)
                BoughtValue(
                    label: "Paid, in \(purchase.paid.currency)",
                    value: purchase.paid.formatted(), isStrong: true)
            }
            PartTimeline(part: part)
            if let error = parts.openError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            let others = parts.options(of: part.id).filter { $0.id != purchase.optionID }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: PartOptionLayout.cardSpacing) {
                    Divider()
                    Button(action: toggleOthers) {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(showsOtherOptions ? 90 : 0))
                            Text(PartMoneyWording.keptOptions(others, rates: money.rates))
                                .lineLimit(1)
                        }
                        .font(.system(size: PageLayout.detailSize))
                        .foregroundStyle(.secondary)
                        .frame(height: BoughtLayout.keptHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("otherOptions")
                    if showsOtherOptions {
                        PartOptionCards(options: others, lowestID: nil, isEditable: isEditable)
                    }
                }
            }
        }
    }

    private var shipping: String {
        guard let shipping = purchase.shipping else { return "None" }
        if shipping == 0 { return "Free" }
        return Money(shipping, purchase.price.currency).formatted()
    }

    private func toggleOthers() { showsOtherOptions.toggle() }
}

private struct BoughtValue: View {
    let label: String
    let value: String
    var isStrong = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: InPlaceLayout.labelSize, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(
                    .system(size: BoughtLayout.valueSize, weight: isStrong ? .semibold : .regular)
                )
                .monospacedDigit()
                .frame(height: BoughtLayout.valueHeight)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// The states after a part is bought, with the day each was reached, or what sets it.
private struct PartTimeline: View {
    let part: PartRecord

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Self.stages, id: \.stage) { step in
                TimelineStep(
                    title: step.stage.rawValue, isReached: part.stage.hasReached(step.stage),
                    detail: detail(of: step.stage) ?? step.hint)
            }
        }
        .padding(.vertical, BoughtLayout.timelineVertical)
        .padding(.horizontal, BoughtLayout.timelineHorizontal)
        .background(
            Color(nsColor: .quaternarySystemFill),
            in: RoundedRectangle(cornerRadius: BoughtLayout.timelineRadius))
    }

    private static let stages: [(stage: PartStage, hint: String)] = [
        (.ordered, "No order day"), (.inHand, "Set when it arrives"),
        (.fitted, "Set when you fit it"),
    ]

    private func detail(of stage: PartStage) -> String? {
        let date: Date? =
            switch stage {
            case .needed: nil
            case .ordered: part.orderedAt
            case .inHand: part.inHandAt
            case .fitted: part.fittedAt
            }
        return date.map { PageLayout.day($0) }
    }
}

private struct TimelineStep: View {
    let title: String
    let isReached: Bool
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isReached ? Color.accentColor : .clear)
                    .overlay {
                        if !isReached {
                            Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1.5)
                        }
                    }
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: PageLayout.detailSize, weight: .semibold))
                    .foregroundStyle(isReached ? .primary : .secondary)
            }
            Text(detail)
                .font(.system(size: PartOptionLayout.smallSize))
                .foregroundStyle(isReached ? .secondary : .tertiary)
                .padding(.leading, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// Values from the "3b Part, after Buy" artboard on the Paper page "Rework · Simple".
private enum BoughtLayout {
    static let spacing: CGFloat = 16
    static let valueSize: CGFloat = 15
    static let valueHeight: CGFloat = 24
    static let timelineVertical: CGFloat = 14
    static let timelineHorizontal: CGFloat = 16
    static let timelineRadius: CGFloat = 12
    static let keptHeight: CGFloat = 40
}
