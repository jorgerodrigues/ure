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

    // The checklist heading's summary, such as "6 of 10 done · 60%", with the skipped tasks
    // counted apart, such as "· 1 skipped".
    var summary: String {
        var parts = ["No tasks planned"]
        if let percentage { parts = ["\(doneCount) of \(countedCount) done", "\(percentage)%"] }
        if skippedCount > 0 { parts.append("\(skippedCount) skipped") }
        return parts.joined(separator: " · ")
    }

    var accessibilitySummary: String {
        guard let percentage else { return "No tasks planned. \(skippedCount) skipped." }
        return
            "\(doneCount) of \(countedCount) tasks done, \(percentage) percent. \(skippedCount) skipped."
    }
}
