import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Application", value: "Ure")
                LabeledContent("Version", value: version)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .scenePadding()
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown"
    }
}
