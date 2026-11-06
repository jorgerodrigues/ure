import Foundation

// A stored value as it was before a change and as it is after it, read in the change's own
// transaction, so Undo can put back what the library held.
nonisolated struct Revision<Value: Equatable & Sendable>: Equatable, Sendable {
    let before: Value
    let after: Value

    var changed: Bool { before != after }
}

// One change to the library, as a value: what to change, never how. The app submits each edit to
// the library's EditQueue at the moment you act, and the queue applies the edits one at a time,
// in that order. Applying an edit reads the rows it changes and gives back the edit that undoes
// it.
nonisolated enum LibraryEdit: Equatable, Sendable {
    case caliber(CaliberEdit)
    case watch(WatchEdit)
    case job(JobEdit)
    case part(PartEdit)
    // Changes steps of a job's checklist, applied to the steps it holds when its turn comes.
    case checklist(UUID, [ChecklistOperation])
    case notes(LibraryItemOwner, String)
    case material(MaterialEdit)
    case money(MoneyEdit)
}

// A record that an edit deletes or archives.
nonisolated enum EndedRecord: Hashable, Sendable {
    case watch(UUID)
    case caliber(UUID)
    case job(UUID)
    case part(UUID)
    case option(UUID)
    case material(UUID)

    init(_ owner: LibraryItemOwner) {
        switch owner {
        case .watch(let id): self = .watch(id)
        case .caliber(let id): self = .caliber(id)
        case .job(let id): self = .job(id)
        }
    }
}

extension LibraryEdit {
    // The record this edit deletes or archives. An edit to that record that ran after it would
    // fail for good, so the record takes no edits while this one waits or runs.
    nonisolated var endedRecord: EndedRecord? {
        switch self {
        case .watch(.archive(let id, true)): .watch(id)
        case .caliber(.archive(let id, true)): .caliber(id)
        case .job(.discardIfBlank(let id)): .job(id)
        case .part(.remove(let id)): .part(id)
        case .part(.removeOption(let id)): .option(id)
        case .material(.remove(let id, _)): .material(id)
        default: nil
        }
    }

    // The spare this edit takes from the drawer, also when Redo or Undo puts a part back on a
    // job. A second use of it would fail for good.
    nonisolated var usedSpare: UUID? {
        switch self {
        case .part(.useSpare(let id, _)): return id
        case .part(.place(let id, let placement)) where placement.jobID != nil: return id
        default: return nil
        }
    }
}

nonisolated enum CaliberEdit: Equatable, Sendable {
    case create
    case set(UUID, CaliberFact)
    case archive(UUID, Bool)
}

nonisolated enum WatchEdit: Equatable, Sendable {
    case create
    case set(UUID, WatchFact)
    case archive(UUID, Bool)
}

nonisolated enum JobEdit: Equatable, Sendable {
    // Starts a job In progress, on a watch or without one.
    case start(UUID?)
    case set(UUID, JobFact)
    case stage(UUID, JobStage)
    // Puts back a state as it was, with its waiting text and done date.
    case restoreStage(UUID, JobStageValue)
    case watch(UUID, UUID?)
    // Makes a watch with the typed name and gives it to the job.
    case newWatch(UUID, String)
    case discardIfBlank(UUID)
}

nonisolated enum PartEdit: Equatable, Sendable {
    // Adds a part to the end of a job's parts, or makes a spare when the job is nil.
    case add(name: String, description: String, job: UUID?)
    case set(UUID, PartFact)
    case advance(UUID)
    case stage(UUID, PartStage)
    case restoreStage(UUID, PartStageValue)
    case useSpare(UUID, job: UUID)
    case place(UUID, PartPlacement)
    case remove(UUID)
    case restore(RemovedPart)
    // Adds a buying option for a link, after the part's other options.
    case addOption(UUID, URL)
    case setOption(UUID, PartOptionFact)
    case removeOption(UUID)
    case restoreOption(PartOption)
    // Records what was bought, and moves a part to buy on to Ordered.
    case markBought(UUID, PartPurchase)
}

// The home currency and the exchange rates in Settings.
nonisolated enum MoneyEdit: Equatable, Sendable {
    // Chooses the home currency, or nil to follow the Mac's region again.
    case setHomeCurrency(String?)
    // The rate of one unit of a currency in a home currency, or nil for no rate.
    case setRate(currency: String, home: String, rate: Decimal?)
}

nonisolated enum MaterialEdit: Equatable, Sendable {
    case importFiles([URL], LibraryItemOwner)
    case addLink(URL, LibraryItemOwner)
    case rename(UUID, String, LibraryItemOwner)
    case setCover(UUID?, watch: UUID)
    case remove(UUID, LibraryItemOwner)
    case restore(RemovedMaterial)
}

// What the library holds after an edit, for the screens that show it.
nonisolated enum LibraryChange: Sendable {
    case caliber(CaliberRecord)
    case watch(WatchRecord)
    case job(JobRecord)
    case jobRemoved(UUID)
    case part(PartRecord)
    case partRemoved(UUID)
    case partOption(PartOption)
    case partOptionRemoved(UUID)
    case checklist(UUID, [ChecklistStepRecord])
    case notes(LibraryItemOwner, String)
    case material(MaterialRecord)
    case materialItem(LibraryItem)
    case materialRemoved(UUID)
    case imported(LibraryItemOwner, [FileImportResult<MaterialRecord>])
}

// An applied edit: what the library now holds, and the edit that undoes it, or nil when the
// edit changed nothing.
nonisolated struct EditApplied: Sendable {
    var changes: [LibraryChange] = []
    var inverse: LibraryEdit? = nil
}

// Applies edits through the services, which own validation and the SQL. Each edit is one service
// call, so it runs in one database transaction.
nonisolated struct LibraryEditor: Sendable {
    let calibers: CaliberService
    let watches: WatchService
    let jobs: JobService
    let parts: PartService
    let checklists: ChecklistService
    let notes: RecordNotesService
    let material: MaterialService
    let archive: ArchiveService
    let money: MoneyService

    init(coordinator: LibraryCoordinator) {
        calibers = CaliberService(coordinator: coordinator)
        watches = WatchService(coordinator: coordinator)
        jobs = JobService(coordinator: coordinator)
        parts = PartService(coordinator: coordinator)
        checklists = ChecklistService(coordinator: coordinator)
        notes = RecordNotesService(coordinator: coordinator)
        material = MaterialService(coordinator: coordinator)
        archive = ArchiveService(coordinator: coordinator)
        money = MoneyService(coordinator: coordinator)
    }

    func apply(_ edit: LibraryEdit) async throws -> EditApplied {
        switch edit {
        case .caliber(let edit): try await apply(edit)
        case .watch(let edit): try await apply(edit)
        case .job(let edit): try await apply(edit)
        case .part(let edit): try await apply(edit)
        case .checklist(let jobID, let operations):
            try await changeChecklist(operations, of: jobID)
        case .notes(let owner, let text):
            try await saveNotes(text, for: owner)
        case .material(let edit): try await apply(edit)
        case .money(let edit): try await apply(edit)
        }
    }

    private func apply(_ edit: CaliberEdit) async throws -> EditApplied {
        switch edit {
        case .create:
            return EditApplied(changes: [.caliber(try await calibers.create())])
        case .set(let id, let fact):
            let revision = try await calibers.update(id, fact)
            return EditApplied(
                changes: [.caliber(revision.after)],
                inverse: revision.changed
                    ? .caliber(.set(id, fact.stored(in: revision.before))) : nil)
        case .archive(let id, let archived):
            let revision = try await archive.setCaliber(id, archived: archived)
            return EditApplied(
                changes: [.caliber(revision.after)],
                inverse: revision.changed ? .caliber(.archive(id, !archived)) : nil)
        }
    }

    private func apply(_ edit: WatchEdit) async throws -> EditApplied {
        switch edit {
        case .create:
            return EditApplied(changes: [.watch(try await watches.create())])
        case .set(let id, let fact):
            let revision = try await watches.update(id, fact)
            return EditApplied(
                changes: [.watch(revision.after)],
                inverse: revision.changed ? .watch(.set(id, fact.stored(in: revision.before))) : nil
            )
        case .archive(let id, let archived):
            let revision = try await archive.setWatch(id, archived: archived)
            return EditApplied(
                changes: [.watch(revision.after)],
                inverse: revision.changed ? .watch(.archive(id, !archived)) : nil)
        }
    }

    private func apply(_ edit: JobEdit) async throws -> EditApplied {
        switch edit {
        case .start(let watchID):
            return EditApplied(changes: [.job(try await jobs.start(for: watchID))])
        case .set(let id, let fact):
            let revision = try await jobs.update(id, fact)
            return EditApplied(
                changes: [.job(revision.after)],
                inverse: revision.changed ? .job(.set(id, fact.stored(in: revision.before))) : nil)
        case .stage(let id, let stage):
            return Self.applied(try await jobs.setStage(id, to: stage), id)
        case .restoreStage(let id, let value):
            return Self.applied(try await jobs.restoreStage(id, to: value), id)
        case .watch(let id, let watchID):
            return Self.applied(try await jobs.setWatch(id, to: watchID), id)
        case .newWatch(let id, let name):
            return Self.applied(try await jobs.setNewWatch(id, named: name), id)
        case .discardIfBlank(let id):
            let removed = try await jobs.discardIfBlank(id)
            return EditApplied(changes: removed ? [.jobRemoved(id)] : [])
        }
    }

    private static func applied(_ change: JobStageChange, _ id: UUID) -> EditApplied {
        let changed = JobStageValue(job: change.job) != change.prior
        return EditApplied(
            changes: [.job(change.job)],
            inverse: changed ? .job(.restoreStage(id, change.prior)) : nil)
    }

    private static func applied(_ revision: Revision<JobRecord>, _ id: UUID) -> EditApplied {
        EditApplied(
            changes: [.job(revision.after)],
            inverse: revision.changed ? .job(.watch(id, revision.before.watchID)) : nil)
    }

    private func apply(_ edit: PartEdit) async throws -> EditApplied {
        switch edit {
        case .add(let name, let description, let jobID):
            let part = try await parts.add(named: name, description: description, to: jobID)
            return EditApplied(changes: [.part(part)], inverse: .part(.remove(part.id)))
        case .set(let id, let fact):
            let revision = try await parts.update(id, fact)
            return EditApplied(
                changes: [.part(revision.after)],
                inverse: revision.changed ? .part(.set(id, fact.stored(in: revision.before))) : nil)
        case .advance(let id):
            return Self.applied(try await parts.advance(id), id)
        case .stage(let id, let stage):
            return Self.applied(try await parts.setStage(id, to: stage), id)
        case .restoreStage(let id, let value):
            return Self.applied(try await parts.restoreStage(id, to: value), id)
        case .useSpare(let id, let jobID):
            return Self.applied(try await parts.useSpare(id, on: jobID), id)
        case .place(let id, let placement):
            return Self.applied(try await parts.place(id, at: placement), id)
        case .remove(let id):
            let removed = try await parts.remove(id)
            return EditApplied(changes: [.partRemoved(id)], inverse: .part(.restore(removed)))
        case .restore(let removed):
            let part = try await parts.restore(removed)
            return EditApplied(
                changes: [.part(part)] + removed.options.map(LibraryChange.partOption),
                inverse: .part(.remove(part.id)))
        case .addOption(let partID, let url):
            let option = try await parts.addOption(url, to: partID)
            return EditApplied(
                changes: [.partOption(option)], inverse: .part(.removeOption(option.id)))
        case .setOption(let id, let fact):
            let revision = try await parts.updateOption(id, fact)
            return EditApplied(
                changes: [.partOption(revision.after)],
                inverse: revision.changed
                    ? .part(.setOption(id, fact.stored(in: revision.before))) : nil)
        case .removeOption(let id):
            let option = try await parts.removeOption(id)
            return EditApplied(
                changes: [.partOptionRemoved(id)], inverse: .part(.restoreOption(option)))
        case .restoreOption(let option):
            let restored = try await parts.restoreOption(option)
            return EditApplied(
                changes: [.partOption(restored)], inverse: .part(.removeOption(restored.id)))
        case .markBought(let id, let purchase):
            return Self.applied(try await parts.markBought(id, purchase), id)
        }
    }

    // The home currency has no Undo, so its edit keeps no inverse. Settings follows both from
    // the library.
    private func apply(_ edit: MoneyEdit) async throws -> EditApplied {
        switch edit {
        case .setHomeCurrency(let code):
            try await money.setHomeCurrency(code)
            return EditApplied()
        case .setRate(let currency, let home, let rate):
            let revision = try await money.setRate(rate, for: currency, home: home)
            return EditApplied(
                inverse: revision.changed
                    ? .money(.setRate(currency: currency, home: home, rate: revision.before))
                    : nil)
        }
    }

    private static func applied(_ change: PartStageChange, _ id: UUID) -> EditApplied {
        let changed = PartStageValue(part: change.part) != change.prior
        return EditApplied(
            changes: [.part(change.part)],
            inverse: changed ? .part(.restoreStage(id, change.prior)) : nil)
    }

    private static func applied(_ revision: Revision<PartRecord>, _ id: UUID) -> EditApplied {
        EditApplied(
            changes: [.part(revision.after)],
            inverse: revision.changed
                ? .part(.place(id, PartPlacement(part: revision.before))) : nil)
    }

    private func changeChecklist(_ operations: [ChecklistOperation], of jobID: UUID)
        async throws -> EditApplied
    {
        let change = try await checklists.apply(operations, for: jobID)
        return EditApplied(
            changes: [.checklist(jobID, change.after)],
            inverse: change.inverse.isEmpty ? nil : .checklist(jobID, change.inverse))
    }

    private func saveNotes(_ text: String, for owner: LibraryItemOwner) async throws
        -> EditApplied
    {
        let revision = try await notes.save(text, for: owner)
        return EditApplied(
            changes: [.notes(owner, revision.after)],
            inverse: revision.changed ? .notes(owner, revision.before) : nil)
    }

    private func apply(_ edit: MaterialEdit) async throws -> EditApplied {
        switch edit {
        case .importFiles(let sources, let owner):
            let results = await material.importFiles(sources, for: owner)
            return EditApplied(changes: [.imported(owner, results)])
        case .addLink(let url, let owner):
            let item = try await material.addLink(url, for: owner)
            return EditApplied(changes: [.material(MaterialRecord(item: item, asset: nil))])
        case .rename(let id, let title, let owner):
            let revision = try await material.rename(id, to: title, for: owner)
            return EditApplied(
                changes: [.materialItem(revision.after)],
                inverse: revision.changed
                    ? .material(.rename(id, revision.before.title, owner)) : nil)
        case .setCover(let photoID, let watchID):
            try await material.setCover(photoID, for: watchID)
            return EditApplied()
        case .remove(let id, let owner):
            let removed = try await material.remove(id, from: owner)
            return EditApplied(
                changes: [.materialRemoved(id)], inverse: .material(.restore(removed)))
        case .restore(let removed):
            let record = try await material.restore(removed)
            guard let owner = record.item.owner else { return EditApplied() }
            return EditApplied(
                changes: [.material(record)], inverse: .material(.remove(record.id, owner)))
        }
    }
}

// Each fact as a record holds it, so Undo of a fact can put back the stored value.
extension CaliberFact {
    nonisolated func stored(in record: CaliberRecord) -> CaliberFact {
        switch self {
        case .name: .name(record.designation)
        case .maker: .maker(record.manufacturer ?? "")
        case .winding: .winding(record.winding)
        case .beatRate: .beatRate(record.beatRate)
        case .jewels: .jewels(record.jewelCount)
        case .powerReserve: .powerReserve(record.powerReserve)
        case .liftAngle: .liftAngle(record.liftAngle)
        }
    }
}

extension WatchFact {
    nonisolated func stored(in record: WatchRecord) -> WatchFact {
        switch self {
        case .name: .name(record.name)
        case .brand: .brand(record.brand ?? "")
        case .model: .model(record.model ?? "")
        case .reference: .reference(record.caseReference ?? "")
        case .serial: .serial(record.serial ?? "")
        case .year: .year(record.approximateYear ?? "")
        case .caliber: .caliber(record.caliberID)
        case .caseMaterial: .caseMaterial(record.caseMaterial ?? "")
        case .diameter: .diameter(record.caseDiameter)
        case .lugWidth: .lugWidth(record.lugWidth)
        case .owner: .owner(record.owner ?? "")
        case .contact: .contact(record.contact ?? "")
        }
    }
}

extension JobFact {
    nonisolated func stored(in record: JobRecord) -> JobFact {
        switch self {
        case .title: .title(record.title)
        case .problem: .problem(record.problem ?? "")
        case .waitingFor: .waitingFor(record.waitingFor ?? "")
        }
    }
}

extension PartFact {
    nonisolated func stored(in record: PartRecord) -> PartFact {
        switch self {
        case .name: .name(record.name)
        case .description: .description(record.description ?? "")
        case .quantity: .quantity(String(record.quantity))
        case .notes: .notes(record.notes)
        }
    }
}

// A price, the shipping and the currency share one currency, and a first amount sets it, so
// their Undo puts back all three as they were stored.
extension PartOptionFact {
    nonisolated func stored(in option: PartOption) -> PartOptionFact {
        switch self {
        case .supplier: .supplier(option.supplier)
        case .note: .note(option.note)
        case .price, .shipping, .currency, .money:
            .money(price: option.price, shipping: option.shipping, currency: option.currency)
        }
    }
}
