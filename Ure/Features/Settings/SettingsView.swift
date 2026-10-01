import SwiftUI

struct SettingsView: View {
    @Environment(LibraryState.self) private var library

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Library folder") {
                    Text(library.coordinator.root.path)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("libraryFolder")
                }
            }
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
