import SwiftUI

// The Record menu's actions for what the detail shows, with the names its toolbar buttons use,
// such as "Edit Part" or "Remove Photo".
struct RecordMenuActions {
    var edit: (() -> Void)?
    var editTitle = "Edit"
    var remove: (() -> Void)?
    var removeTitle = "Remove"
    var exportOriginal: (() -> Void)?
}

// The way back from a detail to the page it belongs to, named as its toolbar button is, such
// as "Back to Job".
struct RecordBack {
    static let watchTitle = "Back to Watch"
    static let jobTitle = "Back to Job"

    let title: String
    let action: () -> Void
}

private struct RecordMenuActionsKey: FocusedValueKey {
    typealias Value = RecordMenuActions
}

private struct RecordBackActionKey: FocusedValueKey {
    typealias Value = RecordBack
}

extension FocusedValues {
    var recordMenuActions: RecordMenuActions? {
        get { self[RecordMenuActionsKey.self] }
        set { self[RecordMenuActionsKey.self] = newValue }
    }
    var recordBackAction: RecordBack? {
        get { self[RecordBackActionKey.self] }
        set { self[RecordBackActionKey.self] = newValue }
    }
}
