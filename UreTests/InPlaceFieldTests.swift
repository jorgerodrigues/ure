import Foundation
import Testing

@testable import Ure

nonisolated struct NumberEntryTests {
    private let portugal = Locale(identifier: "pt_PT")
    private let unitedStates = Locale(identifier: "en_US")

    @Test
    func portugalReadsNumbersAsYouWouldWriteThemOnPaper() throws {
        let read: [(NumberEntry, String, Double?)] = [
            (CaliberNumbers.beatRate, "28800", 28_800),
            (CaliberNumbers.beatRate, "28 800", 28_800),
            (CaliberNumbers.beatRate, "28\u{a0}800vph", 28_800),
            (CaliberNumbers.beatRate, "28.800 VPH", 28_800),
            (CaliberNumbers.beatRate, " 21 600 A/h ", 21_600),
            (CaliberNumbers.liftAngle, "52,5°", 52.5),
            (CaliberNumbers.liftAngle, "52,5 deg", 52.5),
            (CaliberNumbers.liftAngle, ",5°", 0.5),
            (CaliberNumbers.powerReserve, "38,5 hours", 38.5),
            (CaliberNumbers.powerReserve, "40h.", 40),
            (CaliberNumbers.powerReserve, "0", 0),
            (CaliberNumbers.jewels, "17 jewels", 17),
            (CaliberNumbers.jewels, "1.234.567", 1_234_567),
            (CaliberNumbers.jewels, "  ", nil),
        ]
        for (entry, text, value) in read {
            #expect(try entry.value(from: text, locale: portugal) == value, "\(text)")
        }
        let rejected: [(NumberEntry, String, NumberEntryProblem.Kind)] = [
            (CaliberNumbers.liftAngle, "52.5", .notANumber),
            (CaliberNumbers.powerReserve, "1.5 h", .notANumber),
            (CaliberNumbers.beatRate, "28 80", .notANumber),
            (CaliberNumbers.beatRate, "28..800", .notANumber),
            (CaliberNumbers.beatRate, "1,2,3", .notANumber),
            (CaliberNumbers.beatRate, "vph", .notANumber),
            (CaliberNumbers.beatRate, "35mm", .unknownUnit),
            (CaliberNumbers.powerReserve, "40 min", .unknownUnit),
            (CaliberNumbers.jewels, "1e5", .unknownUnit),
            (CaliberNumbers.beatRate, "0 vph", .belowMinimum),
            (CaliberNumbers.powerReserve, "-1", .belowMinimum),
            (CaliberNumbers.jewels, "−3", .belowMinimum),
        ]
        for (entry, text, kind) in rejected {
            #expect(throws: NumberEntryProblem.self, "\(text)") {
                try entry.value(from: text, locale: portugal)
            }
            do {
                _ = try entry.value(from: text, locale: portugal)
            } catch {
                #expect(error.kind == kind, "\(text)")
            }
        }
    }

    @Test
    func unitedStatesReadsNumbersAsYouWouldWriteThemOnPaper() throws {
        let read: [(NumberEntry, String, Double?)] = [
            (CaliberNumbers.beatRate, "28,800", 28_800),
            (CaliberNumbers.beatRate, "28,800 vph", 28_800),
            (CaliberNumbers.beatRate, "28 800bph", 28_800),
            (CaliberNumbers.liftAngle, "52.5°", 52.5),
            (CaliberNumbers.liftAngle, "52.5 degrees", 52.5),
            (CaliberNumbers.powerReserve, "1,234.5 hrs", 1_234.5),
            (CaliberNumbers.jewels, "12,34,567", 1_234_567),
            (CaliberNumbers.jewels, "17", 17),
            (CaliberNumbers.jewels, "", nil),
        ]
        for (entry, text, value) in read {
            #expect(try entry.value(from: text, locale: unitedStates) == value, "\(text)")
        }
        for (entry, text) in [
            (CaliberNumbers.liftAngle, "52,5"), (CaliberNumbers.beatRate, "28,80"),
            (CaliberNumbers.beatRate, "2,88,00"), (CaliberNumbers.beatRate, "1234,567"),
            (CaliberNumbers.beatRate, "28.800.1"), (CaliberNumbers.beatRate, "nan"),
            (CaliberNumbers.beatRate, String(repeating: "9", count: 400)),
        ] {
            #expect(throws: NumberEntryProblem.self, "\(text)") {
                try entry.value(from: text, locale: unitedStates)
            }
        }
    }

    @Test
    func numbersShowInTheRegionFormatWithTheirUnit() throws {
        #expect(CaliberNumbers.beatRate.text(for: 28_800, locale: portugal) == "28\u{a0}800 vph")
        #expect(CaliberNumbers.beatRate.text(for: 28_800, locale: unitedStates) == "28,800 vph")
        #expect(CaliberNumbers.liftAngle.text(for: 52.5, locale: portugal) == "52,5°")
        #expect(CaliberNumbers.liftAngle.text(for: 52.5, locale: unitedStates) == "52.5°")
        #expect(CaliberNumbers.powerReserve.text(for: 40, locale: portugal) == "40 h")
        #expect(CaliberNumbers.jewels.text(for: 17, locale: unitedStates) == "17")
        #expect(CaliberNumbers.jewels.text(for: nil, locale: unitedStates) == "")
        #expect(
            CaliberNumbers.beatRate.normalized("28800vph", locale: portugal) == "28\u{a0}800 vph")
        #expect(CaliberNumbers.beatRate.normalized("not yet", locale: portugal) == "not yet")
        let egypt = Locale(identifier: "ar_EG")
        #expect(try CaliberNumbers.liftAngle.value(from: "٥٢٫٥°", locale: egypt) == 52.5)
        #expect(try CaliberNumbers.beatRate.value(from: "28800 vph", locale: egypt) == 28_800)
        #expect(throws: NumberEntryProblem.self) {
            try CaliberNumbers.jewels.value(from: "1½", locale: unitedStates)
        }
        for locale in [
            portugal, unitedStates, Locale(identifier: "de_CH"), Locale(identifier: "ar_EG"),
            Locale(identifier: "fa_IR"), Locale(identifier: "hi_IN@numbers=deva"),
        ] {
            for value in [0.5, 17, 2_500, 28_800, 1_234_567.125] {
                let text = CaliberNumbers.powerReserve.text(for: value, locale: locale)
                #expect(
                    try CaliberNumbers.powerReserve.value(from: text, locale: locale) == value,
                    "\(text)")
            }
        }
    }

    @Test
    func problemsSayWhatToWriteInTheRegionFormat() {
        #expect(
            CaliberNumbers.beatRate.problem(in: "fast", locale: portugal)
                == "Enter a number, such as 28\u{a0}800 vph.")
        #expect(
            CaliberNumbers.beatRate.problem(in: "28800 Hz", locale: unitedStates)
                == "Enter the beat rate in vph, such as 28,800 vph.")
        #expect(
            CaliberNumbers.jewels.problem(in: "17 rubies", locale: unitedStates)
                == "Enter only the number, such as 17.")
        #expect(
            CaliberNumbers.liftAngle.problem(in: "0", locale: unitedStates)
                == "Enter a lift angle above 0°.")
        #expect(
            CaliberNumbers.powerReserve.problem(in: "-2 h", locale: unitedStates)
                == "Enter a power reserve of 0 h or more.")
        #expect(CaliberNumbers.powerReserve.problem(in: "", locale: unitedStates) == nil)
    }
}

struct FactFieldTests {
    private let unitedStates = Locale(identifier: "en_US")

    @Test(.timeLimit(.minutes(1)))
    func invalidNumberShowsAsNotValidOnLeaveAndTheRecordKeepsTheLastGoodValue() async throws {
        let gate = PauseGate()
        let library = try await FieldLibrary.make()
        let field = beatRate(in: library, gate: gate)
        field.beginEditing()
        field.change(to: "19,8x", undoManager: nil)
        #expect(field.problem == nil && field.hasUnsavedChanges)
        try await gate.elapse()
        field.saveNow()
        await library.queue.waitUntilIdle()
        #expect(field.problem == nil && field.hasUnsavedText)
        #expect(try await library.stored().beatRate == 19_800)

        field.endEditing()
        #expect(field.problem == "Enter a number, such as 28,800 vph.")
        #expect(field.text == "19,8x" && field.editor.savedText == "19,800 vph")
        field.refresh("21,600 vph")
        #expect(field.text == "19,8x" && library.queue.hasUnsavedTyping)

        field.beginEditing()
        #expect(field.problem != nil)
        field.change(to: "21600", undoManager: nil)
        #expect(field.problem == nil)
        field.endEditing()
        try await waitUntil { field.text == "21,600 vph" && !field.hasUnsavedChanges }
        #expect(try await library.stored().beatRate == 21_600 && field.problem == nil)
        try await library.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func undoAfterSaveBringsBackSavedValuesAndNeverAnInvalidText() async throws {
        let gate = PauseGate()
        let library = try await FieldLibrary.make()
        let field = beatRate(in: library, gate: gate)
        let undo = UndoManager()
        undo.groupsByEvent = false
        field.beginEditing()
        undo.beginUndoGrouping()
        field.change(to: "28800", undoManager: undo)
        undo.endUndoGrouping()
        field.endEditing()
        try await waitUntil { field.text == "28,800 vph" && !field.hasUnsavedChanges }
        #expect(undo.undoActionName == "Beat Rate")

        field.beginEditing()
        undo.beginUndoGrouping()
        field.change(to: "fast", undoManager: undo)
        undo.endUndoGrouping()
        field.endEditing()
        #expect(field.problem != nil)

        undo.undo()
        try await waitUntil { field.text == "28,800 vph" && !field.hasUnsavedChanges }
        #expect(field.problem == nil)
        undo.undo()
        try await waitUntil { field.text == "19,800 vph" && !field.hasUnsavedChanges }
        #expect(!undo.canUndo)
        #expect(try await library.stored().beatRate == 19_800)
        undo.redo()
        try await waitUntil { field.text == "28,800 vph" && !field.hasUnsavedChanges }
        #expect(try await library.stored().beatRate == 28_800)
        try await library.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func matchesFromTheLibraryFinishTheTypingAndTakingOnePutsItAllInTheField() async throws {
        let library = try await FieldLibrary.make()
        let makers = [
            FactSuggestion(text: "Omega", detail: "4 calibers"),
            FactSuggestion(text: "Orient", detail: "1 caliber"), FactSuggestion(text: "Oris"),
            FactSuggestion(text: "Zénith"),
        ]
        let field = library.field(
            "Maker", text: "", suggestions: { makers }, fact: CaliberFact.maker,
            shown: { $0.manufacturer ?? "" })
        field.beginEditing()
        field.change(to: "o", undoManager: nil)
        #expect(field.matches.map(\.text) == ["Omega", "Orient", "Oris"])
        #expect(field.suggestion == "Omega" && field.matches.first?.detail == "4 calibers")
        field.change(to: "or", undoManager: nil)
        #expect(field.matches.map(\.text) == ["Orient", "Oris"])
        field.change(to: "o", undoManager: nil)
        #expect(field.matches.isEmpty && field.suggestion == nil)
        field.change(to: "ox", undoManager: nil)
        #expect(field.matches.isEmpty)
        field.change(to: "Z", undoManager: nil)
        #expect(field.matches.isEmpty)
        field.change(to: "Ze", undoManager: nil)
        #expect(field.suggestion == "Zénith")
        #expect(field.acceptSuggestion(undoManager: nil))
        #expect(field.text == "Zénith" && field.matches.isEmpty)
        #expect(!field.acceptSuggestion(undoManager: nil))
        field.change(to: "O", undoManager: nil)
        field.change(to: "Or", undoManager: nil)
        #expect(!field.acceptSuggestion(makers[0], undoManager: nil))
        #expect(field.acceptSuggestion(makers[2], undoManager: nil))
        #expect(field.text == "Oris")
        field.change(to: "Orisx", undoManager: nil)
        #expect(field.matches.isEmpty)
        field.change(to: "M", undoManager: nil)
        field.endEditing()
        #expect(field.matches.isEmpty)
        try await waitUntil { !field.hasUnsavedChanges }
        #expect(try await library.stored().manufacturer == "M")
        try await library.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aChoiceFromAPopUpSavesAtOnceAndUndoesInOneStep() async throws {
        let library = try await FieldLibrary.make(winding: .manual)
        let field = library.field(
            "Winding", text: "Manual", fact: { .winding(Winding(written: $0)) },
            shown: { $0.winding?.rawValue ?? "" })
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        field.choose("Quartz", undoManager: undo)
        undo.endUndoGrouping()
        try await waitUntil { !field.hasUnsavedChanges }
        #expect(try await library.stored().winding == .quartz)
        #expect(!field.isEditing && undo.undoActionName == "Winding")
        undo.undo()
        try await waitUntil { field.text == "Manual" && !field.hasUnsavedChanges }
        #expect(try await library.stored().winding == .manual)
        try await library.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func undoDropsASuggestionMadeForTheTextItTookAway() async throws {
        let library = try await FieldLibrary.make()
        let field = library.field(
            "Maker", text: "", suggestions: { Self.windings }, fact: CaliberFact.maker,
            shown: { $0.manufacturer ?? "" })
        let undo = UndoManager()
        undo.groupsByEvent = false
        field.beginEditing()
        undo.beginUndoGrouping()
        field.change(to: "Au", undoManager: undo)
        undo.endUndoGrouping()
        #expect(field.suggestion == "Automatic")
        undo.undo()
        await library.queue.waitUntilIdle()
        #expect(field.text.isEmpty && field.suggestion == nil)
        #expect(!field.acceptSuggestion(undoManager: undo))
        undo.redo()
        await library.queue.waitUntilIdle()
        #expect(field.text == "Au" && field.suggestion == "Automatic")
        field.endEditing()
        try await waitUntil { !field.hasUnsavedChanges }
        #expect(try await library.stored().manufacturer == "Au")
        try await library.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aBlankNameIsNotValidAndTheRecordKeepsItsName() async throws {
        let library = try await FieldLibrary.make()
        let field = library.field(
            "Name", text: "552", rule: .required("Enter a name."), fact: CaliberFact.name,
            shown: \.designation)
        field.beginEditing()
        field.change(to: "  ", undoManager: nil)
        field.endEditing()
        #expect(field.problem == "Enter a name.")
        field.saveNow()
        #expect(field.hasUnsavedText && library.queue.isIdle)
        field.beginEditing()
        field.change(to: " 552 Elaboré ", undoManager: nil)
        field.endEditing()
        try await waitUntil { field.text == "552 Elaboré" && !field.hasUnsavedChanges }
        #expect(try await library.stored().designation == "552 Elaboré")
        try await library.close()
    }

    private static let windings = ["Manual", "Automatic", "Quartz"].map { FactSuggestion(text: $0) }

    private func beatRate(in library: FieldLibrary, gate: PauseGate) -> FactField {
        let entry = CaliberNumbers.beatRate
        let locale = unitedStates
        return library.field(
            "Beat Rate", text: "19,800 vph", rule: .number(entry, locale: locale),
            fact: { .beatRate(try entry.value(from: $0, locale: locale)) },
            shown: { entry.text(for: $0.beatRate, locale: locale) }, pause: gate.pause)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FactFieldTimeout()
    }
}

// A library with one caliber, "552" at 19,800 vph, whose facts a field types through the
// library's queue. What each edit leaves in the library reaches the field, as a caliber page
// shows it.
final class FieldLibrary {
    let fixture: WatchFixture
    let coordinator: LibraryCoordinator
    let queue: EditQueue
    let caliberID: UUID

    private init(fixture: WatchFixture, coordinator: LibraryCoordinator, caliberID: UUID) {
        self.fixture = fixture
        self.coordinator = coordinator
        self.caliberID = caliberID
        queue = EditQueue(coordinator: coordinator)
    }

    static func make(winding: Winding? = nil) async throws -> FieldLibrary {
        let fixture = WatchFixture()
        let coordinator = fixture.coordinator()
        _ = try await coordinator.open()
        let service = CaliberService(coordinator: coordinator)
        let caliber = try await service.create(named: "552")
        _ = try await service.update(caliber.id, .beatRate(19_800))
        _ = try await service.update(caliber.id, .winding(winding))
        return FieldLibrary(fixture: fixture, coordinator: coordinator, caliberID: caliber.id)
    }

    func field(
        _ actionName: String, text: String, rule: FactRule = .anyText,
        suggestions: @escaping () -> [FactSuggestion] = { [] },
        fact: @escaping (String) throws -> CaliberFact,
        shown: @escaping (CaliberRecord) -> String,
        pause: @escaping (Duration) async throws -> Void = PauseGate().pause
    ) -> FactField {
        let id = caliberID
        let field = FactField(
            label: actionName, prompt: actionName, actionName: actionName, text: text,
            rule: rule, suggestions: suggestions, queue: queue, scope: .calibers,
            edit: { .caliber(.set(id, try fact($0))) }, pause: pause)
        queue.listen { [weak field] change, byUndo in
            guard case .caliber(let record) = change else { return }
            field?.refresh(shown(record), force: byUndo)
        }
        return field
    }

    func stored() async throws -> CaliberRecord {
        let id = caliberID
        return try #require(try await coordinator.read { try CaliberQueries.fetch(id, in: $0) })
    }

    func close() async throws {
        try await coordinator.close()
        fixture.remove()
    }
}

nonisolated private struct FactFieldTimeout: Error {}
