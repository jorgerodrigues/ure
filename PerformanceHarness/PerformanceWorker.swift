import CoreGraphics
import Darwin
import Foundation
import GRDB

@main
struct PerformanceWorker {
    static func main() async {
        do {
            #if DEBUG
                throw PerformanceError.requiresRelease
            #else
                let arguments = CommandLine.arguments
                guard arguments.count == 3 else { throw PerformanceError.invalidArguments }
                let directory = URL(filePath: arguments[2])
                let root = directory.appending(path: "library")
                let environment = ProcessInfo.processInfo.environment
                guard environment["URE_TESTING"] == "1",
                    environment["URE_TEST_LIBRARY_PATH"] == root.path,
                    try Data(contentsOf: directory.appending(path: ".ure-performance-case"))
                        == Data(PerformanceFixture.version.utf8)
                else { throw PerformanceError.notIsolated }
                let coordinator = LibraryCoordinator(root: root)
                switch arguments[1] {
                case "seed":
                    guard !FileManager.default.fileExists(atPath: root.path) else {
                        throw PerformanceError.invalidFixture
                    }
                    _ = try await coordinator.open()
                    try await PerformanceFixture.seed(coordinator, directory: directory)
                case "measure":
                    let start = ContinuousClock.now
                    _ = try await coordinator.open()
                    let openMilliseconds = start.duration(to: .now).milliseconds
                    let runner = PerformanceMeasurements(coordinator: coordinator)
                    var report = try await runner.run()
                    report.openMilliseconds = openMilliseconds
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    FileHandle.standardOutput.write(try encoder.encode(report))
                default: throw PerformanceError.invalidArguments
                }
                try await coordinator.close()
            #endif
        } catch {
            FileHandle.standardError.write(Data("Performance worker failed: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }
}

nonisolated enum PerformanceError: Error {
    case invalidArguments, notIsolated, invalidFixture, changedResults, requiresRelease,
        memoryUnavailable
}

nonisolated extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

nonisolated struct PerformanceReport: Codable, Sendable {
    var openMilliseconds = 0.0
    var timings: [String: [Double]] = [:]
    var firstReadMilliseconds: [String: Double] = [:]
    var resultIDs: [String: [String]] = [:]
    var imageCycles: [ImageCycle] = []
}

nonisolated struct ImageCycle: Codable, Sendable {
    let assetID: String
    let milliseconds: Double
    let width: Int
    let height: Int
    let beforeBytes: UInt64
    let heldBytes: UInt64
    let afterBytes: UInt64
}

nonisolated struct PerformanceMeasurements: Sendable {
    let coordinator: LibraryCoordinator

    func run() async throws -> PerformanceReport {
        var report = PerformanceReport()
        try await measure("watches", into: &report) { db in
            try WatchQueries.fetchAll(db).map { $0.id.uuidString }
        }
        try await measure("jobs", into: &report) { db in
            try JobQueries.fetchAll(db).map { $0.id.uuidString }
        }
        try await measure("tasks", into: &report) { db in
            try TaskPartQueries.snapshot(db).tasks.map { $0.id.uuidString }
        }
        try await measure("photos", into: &report) { db in
            try PhotoQueries.fetchAll(db).map { $0.id.uuidString }
        }
        try await measure("parts", into: &report) { db in
            try PartsOverviewQueries.fetch(db).map { $0.id.uuidString }
        }
        try await measure("bench", into: &report) { db in
            try BenchSnapshot.fetch(db).items.map { $0.id.uuidString }
        }
        try await measure("workshop", into: &report) { db in
            let rows = try WorkshopQueries.fetch(db)
            guard
                rows.allSatisfy({ row in
                    row.progress.doneCount == 2 && row.progress.countedCount == 8
                        && row.progress.skippedCount == 2 && row.unresolvedPartCount == 1
                })
            else { throw PerformanceError.changedResults }
            return rows.map { $0.id.uuidString }
        }
        for archived in [false, true] {
            for text in ["Synthetic", "ÜHREN", "00.A_%", "00.001_%'", "no match"] {
                try await measure("search:\(archived):\(text)", into: &report) { db in
                    try SearchQueries.fetch(text, includeArchived: archived, in: db).map(\.id)
                }
            }
        }
        let service = PhotoService(coordinator: coordinator)
        for index in 0..<30 {
            let assetID = try PerformanceFixture.id(5, index)
            let start = ContinuousClock.now
            let dimensions = try await decode(service, assetID: assetID, thumbnail: true)
            guard dimensions.width <= 256, dimensions.height <= 256 else {
                throw PerformanceError.changedResults
            }
            report.timings["thumbnail", default: []].append(start.duration(to: .now).milliseconds)
        }
        for index in 0..<20 {
            let assetID = try PerformanceFixture.id(5, index * 3 + 2)
            let before = try Self.residentBytes()
            let start = ContinuousClock.now
            let decoded = try await decode(service, assetID: assetID, thumbnail: false)
            let milliseconds = start.duration(to: .now).milliseconds
            guard decoded.width == 6000, decoded.height == 4000 else {
                throw PerformanceError.changedResults
            }
            report.imageCycles.append(
                ImageCycle(
                    assetID: assetID.uuidString, milliseconds: milliseconds,
                    width: decoded.width, height: decoded.height, beforeBytes: before,
                    heldBytes: decoded.residentBytes, afterBytes: try Self.residentBytes()))
        }
        return report
    }

    private func measure(
        _ name: String, into report: inout PerformanceReport,
        query: @Sendable (Database) throws -> [String]
    ) async throws {
        let firstStart = ContinuousClock.now
        let expected = try await coordinator.read(query)
        report.firstReadMilliseconds[name] = firstStart.duration(to: .now).milliseconds
        report.resultIDs[name] = expected
        for _ in 0..<10 {
            let start = ContinuousClock.now
            let result = try await coordinator.read(query)
            let elapsed = start.duration(to: .now).milliseconds
            guard result == expected else { throw PerformanceError.changedResults }
            report.timings[name, default: []].append(elapsed)
        }
    }

    @concurrent
    private func decode(_ service: PhotoService, assetID: UUID, thumbnail: Bool) async throws
        -> (width: Int, height: Int, residentBytes: UInt64)
    {
        let image = try await service.image(for: assetID, thumbnail: thumbnail)
        return try withExtendedLifetime(image) {
            (image.width, image.height, try Self.residentBytes())
        }
    }

    private static func residentBytes() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw PerformanceError.memoryUnavailable }
        return info.resident_size
    }
}
