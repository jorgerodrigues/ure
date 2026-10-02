import SwiftUI

struct CaliberSpecificationsView: View {
    let caliber: CaliberRecord

    var body: some View {
        LabeledContent("Manufacturer", value: caliber.manufacturer ?? "Unknown")
        LabeledContent("Designation", value: caliber.designation)
        LabeledContent("Variant", value: caliber.variant ?? "Unknown")
        LabeledContent("Movement type", value: caliber.movementType.rawValue)
        CaliberNumber(label: "Beat rate", value: caliber.beatRate, unit: "vph")
        CaliberNumber(label: "Jewel count", value: caliber.jewelCount, unit: nil)
        CaliberNumber(label: "Nominal power reserve", value: caliber.powerReserve, unit: "hours")
        CaliberNumber(label: "Lift angle", value: caliber.liftAngle, unit: "degrees")
        if let notes = caliber.specificationNotes {
            LabeledContent("Specification notes") { Text(notes) }
        }
        if let source = caliber.sourceNote {
            LabeledContent("Source note") { Text(source) }
        }
    }
}

private struct CaliberNumber: View {
    let label: String
    let value: Double?
    let unit: String?

    var body: some View {
        LabeledContent(label) {
            if let value {
                if let unit {
                    Text("\(value.formatted()) \(unit)")
                } else {
                    Text(value.formatted())
                }
            } else {
                Text("Unknown")
            }
        }
    }
}
