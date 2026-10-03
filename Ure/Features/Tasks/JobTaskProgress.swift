nonisolated struct JobTaskProgress: Equatable, Sendable {
    let doneCount: Int
    let countedCount: Int
    let skippedCount: Int

    init(tasks: [JobTaskRecord]) {
        doneCount = tasks.filter { $0.status == .done }.count
        skippedCount = tasks.filter { $0.status == .skipped }.count
        countedCount = tasks.count - skippedCount
    }

    var fraction: Double? {
        guard countedCount > 0 else { return nil }
        return Double(doneCount) / Double(countedCount)
    }

    var percentage: Int? {
        guard countedCount > 0 else { return nil }
        return doneCount * 100 / countedCount
    }
}
