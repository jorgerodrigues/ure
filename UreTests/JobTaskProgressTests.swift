import Foundation
import Testing

@testable import Ure

nonisolated struct JobTaskProgressTests {
    @Test
    func emptyAndAllSkippedHaveNoCountedProgress() throws {
        for statuses in [[], [JobTaskStatus.skipped, .skipped]] {
            let progress = try progress(statuses)
            #expect(progress.doneCount == 0 && progress.countedCount == 0)
            #expect(progress.skippedCount == statuses.count)
            #expect(progress.fraction == nil && progress.percentage == nil)
        }
    }

    @Test
    func mixedTasksCountDoingAndWaitingButExcludeSkipped() throws {
        let progress = try progress([.done, .done, .toDo, .doing, .waiting, .skipped])
        #expect(progress.doneCount == 2 && progress.countedCount == 5)
        #expect(progress.skippedCount == 1)
        #expect(progress.fraction == 0.4 && progress.percentage == 40)
    }

    @Test
    func addingAndReopeningReduceProgress() throws {
        #expect(try progress([.done, .done]).percentage == 100)
        #expect(try progress([.done, .done, .toDo]).percentage == 66)
        #expect(try progress([.done, .doing, .toDo]).percentage == 33)
        #expect(try progress([.done, .doing, .toDo]).doneCount == 1)
        #expect(try progress([.done, .doing, .toDo]).countedCount == 3)
    }

    @Test
    func percentageNeverClaimsCompletionWithUnfinishedWork() throws {
        let statuses = Array(repeating: JobTaskStatus.done, count: 999) + [.waiting]
        #expect(try progress(statuses).percentage == 99)
        #expect(
            try progress(Array(repeating: .done, count: 29) + Array(repeating: .toDo, count: 71))
                .percentage == 29)
    }

    private func progress(_ statuses: [JobTaskStatus]) throws -> JobTaskProgress {
        let jobID = UUID()
        let date = Date(timeIntervalSince1970: 1_000)
        let tasks = try statuses.enumerated().map { position, status in
            try JobTaskFixture.draft(status).record(
                id: UUID(), jobID: jobID, position: position, createdAt: date, updatedAt: date)
        }
        return JobTaskProgress(tasks: tasks)
    }
}
