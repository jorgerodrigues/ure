import SwiftUI

struct RecordMenuActions {
    var edit: (() -> Void)?
    var remove: (() -> Void)?
    var exportOriginal: (() -> Void)?
    var changeStage: (() -> Void)?
    var changeCondition: (() -> Void)?
    var reopen: (() -> Void)?
}

private struct RecordMenuActionsKey: FocusedValueKey {
    typealias Value = RecordMenuActions
}

private struct RecordBackActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var recordMenuActions: RecordMenuActions? {
        get { self[RecordMenuActionsKey.self] }
        set { self[RecordMenuActionsKey.self] = newValue }
    }
    var recordBackAction: (() -> Void)? {
        get { self[RecordBackActionKey.self] }
        set { self[RecordBackActionKey.self] = newValue }
    }
}
