import Foundation

// A watch the picker offers for a job: the watch, its brand, year and caliber, such as
// "Hamilton · 1940s · Hamilton 992B", and its open job when it has one.
struct WatchChoice: Identifiable, Equatable {
    let watch: WatchRecord
    let detail: String
    let openJob: JobRecord?

    var id: UUID { watch.id }
}

// One row of the picker: a watch, or a new watch with the name you typed.
enum WatchPickerItem: Identifiable, Equatable {
    case watch(WatchChoice)
    case newWatch(String)

    var id: String {
        switch self {
        case .watch(let choice): choice.id.uuidString
        case .newWatch: "newWatch"
        }
    }
}

// Finds the watches for a job's picker by name, brand or caliber, at most six, in order of
// name. Archived watches can't take a new job, so the picker leaves them out. A watch that has
// an open job still shows after the others, says so, and picking it opens that job. Under them
// comes a new watch with the name you typed.
enum WatchPickerMatches {
    static let limit = 6

    static func items(
        for query: String, watches: [WatchRecord], calibers: [CaliberRecord], jobs: [JobRecord]
    ) -> [WatchPickerItem] {
        let caliberTitles = Dictionary(uniqueKeysWithValues: calibers.map { ($0.id, $0.title) })
        let openJobs = Dictionary(
            jobs.filter(\.stage.isOpen).compactMap { job in job.watchID.map { ($0, job) } },
            uniquingKeysWith: { first, _ in first })
        let choices = watches.filter { $0.archivedAt == nil }
            .filter { watch in
                SearchKey.matches(
                    [watch.name, watch.brand, watch.caliberID.flatMap { caliberTitles[$0] }],
                    query: query)
            }
            // Watches free for a job come first, so Return takes one of them.
            .sorted { lhs, rhs in
                let lhsBusy = openJobs[lhs.id] != nil
                let rhsBusy = openJobs[rhs.id] != nil
                if lhsBusy != rhsBusy { return !lhsBusy }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .prefix(limit)
            .map { watch in
                let caliber = watch.caliberID.flatMap { caliberTitles[$0] }
                let openJob = openJobs[watch.id]
                var parts = [watch.brand, watch.approximateYear, caliber].compactMap { $0 }
                if openJob != nil { parts.append("already has an open job") }
                return WatchPickerItem.watch(
                    WatchChoice(
                        watch: watch, detail: parts.joined(separator: " · "), openJob: openJob))
            }
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return choices }
        return choices + [.newWatch(name)]
    }
}
