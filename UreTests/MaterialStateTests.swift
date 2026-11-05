import Foundation
import GRDB
import Testing

@testable import Ure

struct MaterialStateTests {
    @Test(.timeLimit(.minutes(1)))
    func pastingACompleteAddressAddsALinkAndOtherTextOnlyExplainsWhy() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let state = MaterialState(service: MaterialService(coordinator: coordinator))
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { !state.isLoading }

        #expect(await state.paste("https://example.org/service-guide", for: owner))
        let link = try #require(state.records(for: owner).first)
        #expect(link.item.kind == .link && link.item.title == "example.org")
        #expect(link.item.url == "https://example.org/service-guide")
        #expect(state.titleField(for: link.id)?.text == "example.org")
        #expect(state.errors[owner] == nil)

        #expect(!(await state.paste("https://", for: owner)))
        #expect(state.errors[owner] == LinkError.invalidURL.localizedDescription)
        #expect(!(await state.paste("Mainspring is set", for: owner)))
        #expect(state.errors[owner] == LinkError.notALink.localizedDescription)
        #expect(!(await state.paste(nil, for: owner)))
        try await waitUntil { state.records.count == 1 }
        #expect(try await coordinator.read(MaterialQueries.fetchAll).map(\.id) == [link.id])
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func removalIsUndoneAndRedoneAndTheOriginalStaysUntilTheLibraryOpensAgain() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let service = MaterialService(coordinator: coordinator)
        let source = try fixture.source(type: .png)
        let photo = try #require(await service.importFiles([source], for: owners[0]).first)
            .outcome.get()
        let watch = try #require(try await coordinator.read(WatchQueries.fetchAll).first)
        try await service.setCover(photo.id, for: watch.id)
        let original = try await coordinator.originalURL(for: try #require(photo.asset).id)
        let state = MaterialState(service: service)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { state.records.count == 1 }
        let undo = UndoManager()
        undo.groupsByEvent = false

        undo.beginUndoGrouping()
        let record = try #require(state.records.first)
        #expect(await state.remove(record, on: owners[0], undoManager: undo))
        undo.endUndoGrouping()
        #expect(state.records(for: owners[0]).isEmpty)
        #expect(undo.undoActionName == "Remove Photo")
        #expect(try await coordinator.read(WatchQueries.fetchAll).first?.coverPhotoID == nil)
        #expect(FileManager.default.fileExists(atPath: original.path))

        undo.undo()
        await state.waitForChanges()
        try await waitUntil { state.records.count == 1 }
        #expect(state.records.first?.item == photo.item)
        #expect(try await coordinator.read(WatchQueries.fetchAll).first?.coverPhotoID == photo.id)
        #expect(undo.canRedo && undo.redoActionName == "Remove Photo")

        undo.redo()
        await state.waitForChanges()
        try await waitUntil { state.records.isEmpty }
        #expect(undo.canUndo && state.errors[owners[0]] == nil)
        #expect(FileManager.default.fileExists(atPath: original.path))

        state.discardUndo()
        #expect(!undo.canUndo)
        observation.cancel()
        try await coordinator.close()
        let reopened = LibraryCoordinator(root: fixture.root)
        _ = try await reopened.open()
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try await reopened.read(FileAssetQueries.fetchAll).isEmpty)
        try await reopened.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func undoAfterRedoRestoresTheCoverChosenInBetween() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let service = MaterialService(coordinator: coordinator)
        let photo = try await MaterialFixture.file(
            try fixture.source(type: .png), for: owners[0], in: coordinator)
        let watch = try #require(try await coordinator.read(WatchQueries.fetchAll).first)
        let state = MaterialState(service: service)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { state.records.count == 1 }
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        #expect(
            await state.remove(try #require(state.records.first), on: owners[0], undoManager: undo))
        undo.endUndoGrouping()
        undo.undo()
        await state.waitForChanges()
        try await waitUntil { state.records.count == 1 }
        try await service.setCover(photo.id, for: watch.id)
        undo.redo()
        await state.waitForChanges()
        #expect(try await coordinator.read(WatchQueries.fetchAll).first?.coverPhotoID == nil)
        undo.undo()
        await state.waitForChanges()
        try await waitUntil { state.records.count == 1 }
        #expect(try await coordinator.read(WatchQueries.fetchAll).first?.coverPhotoID == photo.id)
        observation.cancel()
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aTitleSavesAsYouTypeAndABlankTitlePutsBackTheOldOne() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let service = MaterialService(coordinator: coordinator)
        let pdf = try #require(
            await service.importFiles([try DocumentFixture.source(in: fixture)], for: owner).first
        ).outcome.get()
        let gate = MaterialPauseGate()
        let state = MaterialState(service: service, pause: gate.pause)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { state.records.count == 1 }
        let field = try #require(state.titleField(for: pdf.id))
        let undo = UndoManager()
        undo.groupsByEvent = false

        field.beginEditing()
        undo.beginUndoGrouping()
        field.change(to: "Service guide", undoManager: undo)
        undo.endUndoGrouping()
        #expect(state.hasUnsavedTitles)
        try await gate.elapse()
        try await waitUntil { field.savedText == "Service guide" }
        try await waitUntil { state.records.first?.item.title == "Service guide" }
        state.endEditingTitle(field, undoManager: undo)
        #expect(undo.undoActionName == "Rename")
        undo.undo()
        try await waitUntil { state.records.first?.item.title == pdf.item.title }

        field.beginEditing()
        undo.beginUndoGrouping()
        field.change(to: "  ", undoManager: undo)
        undo.endUndoGrouping()
        try await gate.elapse()
        #expect(await !field.flush())
        #expect(field.savedText == pdf.item.title)
        #expect(state.records.first?.item.title == pdf.item.title)
        undo.beginUndoGrouping()
        state.endEditingTitle(field, undoManager: undo)
        undo.endUndoGrouping()
        try await waitUntil { !field.hasUnsavedChanges && field.text == pdf.item.title }

        field.beginEditing()
        field.change(to: "Typed before quitting", undoManager: nil)
        #expect(await state.saveAllTitles())
        #expect(
            try await coordinator.read(LibraryItemQueries.fetchAll).first?.title
                == "Typed before quitting")
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func undoNeverBringsBackABlankTitle() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let service = MaterialService(coordinator: coordinator)
        let link = try await service.addLink(
            try #require(URL(string: "https://example.org")), for: owner)
        let gate = MaterialPauseGate()
        let state = MaterialState(service: service, pause: gate.pause)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { state.records.count == 1 }
        let field = try #require(state.titleField(for: link.id))
        let undo = UndoManager()
        undo.groupsByEvent = false

        field.beginEditing()
        undo.beginUndoGrouping()
        field.change(to: "", undoManager: undo)
        undo.endUndoGrouping()
        try await gate.elapse()
        #expect(await !field.flush())
        #expect(field.savedText == "example.org")
        // A burst that starts from a blank title registers no Undo, so it needs no group.
        field.change(to: "Supplier page", undoManager: undo)
        try await gate.elapse()
        try await waitUntil { field.savedText == "Supplier page" }
        state.endEditingTitle(field, undoManager: undo)
        try await waitUntil { state.records.first?.item.title == "Supplier page" }
        undo.undo()
        try await waitUntil {
            !field.hasUnsavedChanges && state.records.first?.item.title == "example.org"
        }
        #expect(field.text == "example.org" && !undo.canUndo)

        field.beginEditing()
        undo.beginUndoGrouping()
        field.change(to: " ", undoManager: undo)
        undo.endUndoGrouping()
        try await gate.elapse()
        #expect(await !field.flush())
        state.endEditingTitle(field, undoManager: undo)
        try await waitUntil { !field.hasUnsavedChanges && field.text == "example.org" }
        while undo.canUndo {
            undo.undo()
            try await waitUntil { !field.hasUnsavedChanges }
            #expect(!field.text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        #expect(
            try await coordinator.read(LibraryItemQueries.fetchAll).first?.title == "example.org")
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func removingMaterialSavesItsTypedTitleFirstAndLeavesNothingUnsaved() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let service = MaterialService(coordinator: coordinator)
        let link = try await service.addLink(
            try #require(URL(string: "https://example.org")), for: owner)
        let gate = MaterialPauseGate()
        let state = MaterialState(service: service, pause: gate.pause)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { state.records.count == 1 }
        let field = try #require(state.titleField(for: link.id))
        field.beginEditing()
        field.change(to: "Typed before removal", undoManager: nil)
        #expect(state.hasUnsavedTitles)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let record = try #require(state.records.first)
        #expect(await state.remove(record, on: owner, undoManager: undo))
        undo.endUndoGrouping()
        #expect(!state.hasUnsavedTitles && state.records.isEmpty)
        undo.undo()
        await state.waitForChanges()
        try await waitUntil { state.records.count == 1 }
        #expect(state.records.first?.item.title == "Typed before removal")
        #expect(!state.hasUnsavedTitles)
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func caliberMaterialOpensFromAWatchPageAndStaysOnTheCaliber() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let coordinator = LibraryCoordinator(root: fixture.root)
        _ = try await coordinator.open()
        let owners = try await ReferenceFixture.owners(coordinator)
        let browser = MaterialBrowserSpy()
        let service = MaterialService(coordinator: coordinator, openBrowser: browser.open)
        let png = try fixture.source(type: .png)
        let photos = try await service.importFiles([png, png], for: owners[2]).map {
            try $0.outcome.get()
        }
        let link = try await service.addLink(
            try #require(URL(string: "https://example.org/552")), for: owners[2])
        let state = MaterialState(service: service)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await waitUntil { state.records.count == 3 }
        let watchPage = owners[0]

        state.open(try #require(state.records.first { $0.id == photos[0].id }), on: watchPage)
        #expect(state.isPresenting(on: watchPage) && !state.isPresenting(on: owners[2]))
        #expect(state.presentedRecord?.item.caliberID != nil)
        #expect(!state.canRemove(try #require(state.presentedRecord), on: watchPage))
        #expect(
            !(await state.remove(
                try #require(state.presentedRecord), on: watchPage, undoManager: nil)))
        #expect(state.canMove(by: 1) && !state.canMove(by: -1))
        state.moveSelection(by: 1)
        #expect(state.presentedRecord?.id == photos[1].id && state.presented?.page == watchPage)

        state.open(try #require(state.records.first { $0.id == link.id }), on: watchPage)
        #expect(browser.urls == [URL(string: "https://example.org/552")])
        #expect(state.presentedRecord?.id == photos[1].id)

        _ = try await service.remove(photos[1].id, from: owners[2])
        try await waitUntil { state.presented == nil }
        #expect(!state.isPresenting(on: watchPage))
        #expect(try await coordinator.read(MaterialQueries.fetchAll).count == 2)
        try await coordinator.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func titlesSaveWhenNavigatingWithoutTheDraftQuestion() async throws {
        let fixture = WatchFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let owner = try #require(try await ReferenceFixture.owners(coordinator).first)
        let service = MaterialService(coordinator: coordinator)
        let link = try await service.addLink(
            try #require(URL(string: "https://example.org")), for: owner)
        let gate = MaterialPauseGate()
        let material = MaterialState(service: service, pause: gate.pause)
        let observation = Task { await material.observe() }
        defer { observation.cancel() }
        try await waitUntil { material.records.count == 1 }
        let editing = MaterialEditingFixture.editing(coordinator, material: material)
        let field = try #require(material.titleField(for: link.id))
        field.beginEditing()
        field.change(to: "Supplier page", undoManager: nil)
        #expect(editing.hasUnsavedFields && !editing.hasUnsavedChanges)
        var navigated = false
        editing.requestNavigation { navigated = true }
        #expect(navigated && !editing.showsUnsavedChanges)
        try await waitUntil { !editing.hasUnsavedFields }
        #expect(
            try await coordinator.read(LibraryItemQueries.fetchAll).first?.title == "Supplier page")
        try await coordinator.close()
    }
}

enum MaterialEditingFixture {
    static func editing(_ coordinator: LibraryCoordinator, material: MaterialState? = nil)
        -> WorkshopEditing
    {
        WorkshopEditing(
            watches: WatchState(service: WatchService(coordinator: coordinator)),
            calibers: CaliberState(service: CaliberService(coordinator: coordinator)),
            jobs: JobState(service: JobService(coordinator: coordinator)),
            notes: RecordNotesState(service: RecordNotesService(coordinator: coordinator)),
            material: material ?? MaterialState(service: MaterialService(coordinator: coordinator)),
            tasks: JobTaskState(service: JobTaskService(coordinator: coordinator)),
            parts: PartState(service: PartService(coordinator: coordinator)))
    }
}

private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw MaterialTimeout()
}

nonisolated private struct MaterialTimeout: Error {}

// Holds each typing pause until the test lets the time pass.
private final class MaterialPauseGate {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func pause(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    func elapse() async throws {
        try await waitUntil { !waiters.isEmpty }
        let current = waiters
        waiters = [:]
        for continuation in current.values { continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
