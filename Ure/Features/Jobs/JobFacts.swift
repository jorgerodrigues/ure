import Foundation

// The facts on one job's page that you write in place: its title, the problem, and what it
// waits for while it is Waiting. Each saves on its own as you type, with Undo.
struct JobFacts {
    let title: FactField
    let problem: AutosaveField
    let waitingFor: FactField

    var editors: [AutosaveField] { [title.editor, waitingFor.editor, problem] }
    var hasUnsavedChanges: Bool { editors.contains { $0.hasUnsavedChanges } }

    // A waiting text saves only once state changes still saving have finished, and only while
    // the job still waits, so Undo of a state and of its text land in the order they were made.
    init(
        job: JobRecord, service: JobService, stillWaits: @escaping () async -> Bool = { true },
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        let id = job.id
        title = FactField(
            label: "Title", prompt: "Title", actionName: "Title", text: job.title,
            rule: .required("Enter a title."),
            save: { text in _ = try await service.update(id, .title(text)) }, pause: pause)
        problem = AutosaveField(
            text: job.problem ?? "", actionName: "Problem",
            save: { text in _ = try await service.update(id, .problem(text)) }, pause: pause)
        waitingFor = FactField(
            label: "Waiting for", prompt: "Add what it waits for", actionName: "Waiting For",
            text: job.waitingFor ?? "", rule: .anyText,
            save: { text in
                guard await stillWaits() else { return }
                _ = try await service.update(id, .waitingFor(text))
            }, pause: pause)
    }

    // Shows the stored values in every field that has nothing waiting to save.
    func refresh(_ job: JobRecord) {
        title.refresh(job.title)
        problem.refresh(job.problem ?? "")
        waitingFor.refresh(job.waitingFor ?? "")
    }
}
