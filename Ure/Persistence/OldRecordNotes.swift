import Foundation

// When a migration removes a field, its value goes into the owning record's notes under one
// heading, so nothing typed is lost.
nonisolated enum OldRecordNotes {
    static let heading = "From the old record"

    // Adds the entries after the existing notes, with one blank line between them. The heading
    // comes first unless the notes already have it, because an earlier migration wrote values
    // there. The existing text keeps every character.
    static func appending(_ entries: [String], to notes: String) -> String {
        guard !entries.isEmpty else { return notes }
        let hasHeading = notes.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0 == heading }
        let block = ((hasHeading ? [] : [heading]) + entries).joined(separator: "\n\n")
        if notes.isEmpty || notes.hasSuffix("\n\n") { return notes + block }
        if notes.hasSuffix("\n") { return notes + "\n" + block }
        return notes + "\n\n" + block
    }

    // A value without its trailing spaces and line breaks, or nil when it holds no text.
    static func kept(_ value: String?) -> String? {
        guard var value else { return nil }
        while let last = value.last, last.isWhitespace { value.removeLast() }
        guard value.contains(where: { !$0.isWhitespace }) else { return nil }
        return value
    }
}
