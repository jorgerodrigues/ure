import SwiftUI

// A caliber's facts as a watch page shows them. They are written on the caliber's own page.
struct CaliberSpecificationsView: View {
    let caliber: CaliberRecord

    var body: some View {
        LabeledContent("Caliber", value: caliber.designation)
        LabeledContent("Maker", value: caliber.manufacturer ?? "Unknown")
        LabeledContent("Winding", value: caliber.winding?.rawValue ?? "Unknown")
        CaliberNumber(label: "Beat rate", value: caliber.beatRate, entry: CaliberNumbers.beatRate)
        CaliberNumber(label: "Jewels", value: caliber.jewelCount, entry: CaliberNumbers.jewels)
        CaliberNumber(
            label: "Power reserve", value: caliber.powerReserve,
            entry: CaliberNumbers.powerReserve)
        CaliberNumber(
            label: "Lift angle", value: caliber.liftAngle, entry: CaliberNumbers.liftAngle)
    }
}

private struct CaliberNumber: View {
    let label: String
    let value: Double?
    let entry: NumberEntry

    var body: some View {
        if value == nil {
            LabeledContent(label, value: "Unknown")
        } else {
            LabeledContent(label, value: entry.text(for: value, locale: .autoupdatingCurrent))
        }
    }
}
