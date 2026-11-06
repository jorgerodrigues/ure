import Foundation

// The facts on one job's page that you write in place: its title, the problem, and what it
// waits for while it is Waiting. Each saves on its own as you type, as an edit on the library's
// queue, with Undo.
struct JobFacts {
    let title: FactField
    let problem: AutosaveField
    let waitingFor: FactField

    var editors: [AutosaveField] { [title.editor, waitingFor.editor, problem] }
    // A field holds text that has not saved, such as a blank title.
    var hasUnsavedText: Bool { editors.contains(where: \.hasUnsavedText) }
    // A field holds text it does not take, such as a blank title.
    var hasRefusedText: Bool { editors.contains(where: \.isRefused) }

    // Tries text whose save failed once more.
    func saveFailedText() {
        for editor in editors { editor.saveFailedText() }
    }

    init(
        job: JobRecord, queue: EditQueue,
        pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        let id = job.id
        title = FactField(
            label: "Title", prompt: "Title", actionName: "Title", text: job.title,
            rule: .required("Enter a title."), queue: queue, scope: .jobs,
            edit: { .job(.set(id, .title($0))) }, pause: pause)
        problem = AutosaveField(
            text: job.problem ?? "", actionName: "Problem", queue: queue, scope: .jobs,
            edit: { .job(.set(id, .problem($0))) }, pause: pause)
        waitingFor = FactField(
            label: "Waiting for", prompt: "Add what it waits for", actionName: "Waiting For",
            text: job.waitingFor ?? "", rule: .anyText, queue: queue, scope: .jobs,
            edit: { .job(.set(id, .waitingFor($0))) }, pause: pause)
    }

    // Shows the stored values in every field that has nothing waiting to save. After Undo and
    // Redo the fields take them also while one has the cursor.
    func refresh(_ job: JobRecord, force: Bool = false) {
        title.refresh(job.title, force: force)
        problem.refresh(job.problem ?? "", force: force)
        waitingFor.refresh(job.waitingFor ?? "", force: force)
    }
}
