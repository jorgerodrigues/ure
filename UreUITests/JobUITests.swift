import Foundation
import XCTest

nonisolated final class JobUITests: XCTestCase {
    @MainActor
    func testTimelineNotesTransitionsSourceNavigationAndRestart() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        createWatch(app)
        app.buttons["startWatchJob"].click()
        enter("Repair history", in: "jobTitle", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["showJobActivity"].waitForExistence(timeout: 5))
        app.buttons["showJobActivity"].click()
        XCTAssertTrue(app.staticTexts["No activity or job notes yet."].waitForExistence(timeout: 5))
        app.buttons["backFromActivity"].click()
        app.buttons["addNote"].click()
        enter("Inspection finding", in: "noteTitle", app: app)
        app.buttons["saveNote"].click()
        XCTAssertTrue(app.buttons["backFromNote"].waitForExistence(timeout: 5))
        app.buttons["backFromNote"].click()
        app.buttons["addTask"].click()
        enter("Inspect escapement", in: "taskTitle", app: app)
        choose("Done", picker: "taskStatus", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["backFromTask"].waitForExistence(timeout: 5))
        app.buttons["backFromTask"].click()
        app.buttons["showJobActivity"].click()
        XCTAssertTrue(app.staticTexts["Created as Done"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "Open Note: Inspection finding").count, 1)
        app.buttons["Open Note: Inspection finding"].click()
        XCTAssertTrue(app.buttons["editNote"].waitForExistence(timeout: 5))
        app.buttons["editNote"].click()
        enter("Corrected finding", in: "noteTitle", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["backFromNote"].waitForExistence(timeout: 5))
        app.buttons["backFromNote"].click()
        app.buttons["showJobActivity"].click()
        XCTAssertTrue(app.staticTexts["Corrected finding"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "Open Note: Corrected finding").count, 1)
        XCTAssertFalse(app.staticTexts["Inspection finding"].exists)
        app.buttons["Open Task: Inspect escapement"].click()
        XCTAssertTrue(app.buttons["editTask"].waitForExistence(timeout: 5))
        app.buttons["backFromTask"].click()
        app.buttons["changeJobStage"].click()
        choose("Completed", picker: "jobStage", app: app)
        enter("Repair checked", in: "jobOutcome", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["reopenJob"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["showJobActivity"].waitForExistence(timeout: 5))
        app.buttons["showJobActivity"].click()
        XCTAssertTrue(app.staticTexts["Planned to Completed"].waitForExistence(timeout: 5))
        app.buttons["Open Note: Corrected finding"].click()
        XCTAssertTrue(app.buttons["editNote"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editNote"].isEnabled)
    }

    @MainActor
    func testIntakeHistorySnapshotAndRestart() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        createWatch(app)
        app.buttons["startWatchJob"].click()
        enter("Inspect movement", in: "jobTitle", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editJob"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Planned"].exists)
        XCTAssertTrue(app.staticTexts["000042.7-A"].exists)
        app.buttons["backToWatch"].click()
        XCTAssertTrue(app.buttons["startWatchJob"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["startWatchJob"].label, "Open Job")
        app.buttons["editWatch"].click()
        enter("Renamed watch", in: "watchName", app: app)
        enter("Changed serial", in: "watchSerial", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["startWatchJob"].waitForExistence(timeout: 5))
        app.buttons["startWatchJob"].click()
        XCTAssertTrue(app.buttons["editJob"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Inherited watch"].exists)
        XCTAssertTrue(app.staticTexts["000042.7-A"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["editJob"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Inspect movement"].exists)
        XCTAssertTrue(app.staticTexts["000042.7-A"].exists)
    }

    @MainActor
    func testReferenceWindowDoesNotSaveOrReplaceTheMainDraft() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        createWatch(app)
        app.buttons["startWatchJob"].click()
        enter("Bench repair", in: "jobTitle", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["addReference"].waitForExistence(timeout: 5))
        app.buttons["addReference"].click()
        enter("Bench sheet", in: "referenceTitle", app: app)
        enter("https://example.org/bench", in: "referenceURL", app: app)
        app.buttons["saveReference"].click()
        XCTAssertTrue(app.buttons["backFromReference"].waitForExistence(timeout: 5))
        app.buttons["backFromReference"].click()
        let pin = app.descendants(matching: .any)["pinReference"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.click()
        app.windows.firstMatch.menuItems["Job · Link · Bench sheet"].click()
        app.buttons["addNote"].click()
        enter("Unfinished note", in: "noteTitle", app: app)
        let main = app.windows.firstMatch
        main.typeKey("r", modifierFlags: [.command, .option])
        let reference = app.windows["Reference"]
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        XCTAssertTrue(reference.staticTexts["Bench sheet"].exists)
        XCTAssertFalse(reference.buttons["saveNote"].exists)
        reference.typeKey("s", modifierFlags: .command)
        reference.typeKey("n", modifierFlags: .command)
        reference.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.textFields["noteTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["noteTitle"].value as? String, "Unfinished note")
        XCTAssertTrue(app.buttons["saveNote"].exists)
        app.buttons["backFromNote"].click()
        XCTAssertTrue(app.sheets.buttons["Stay"].waitForExistence(timeout: 3))
        app.sheets.buttons["Stay"].click()
        XCTAssertEqual(app.textFields["noteTitle"].value as? String, "Unfinished note")
    }

    @MainActor
    func testCancelledIntakeAndDirtyNavigation() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        createWatch(app)
        app.buttons["startWatchJob"].click()
        enter("Cancelled intake", in: "jobTitle", app: app)
        app.buttons["cancelJob"].click()
        XCTAssertTrue(app.buttons["startWatchJob"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["startWatchJob"].label, "Start Job")
        app.buttons["startWatchJob"].click()
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["jobSaveError"].waitForExistence(timeout: 5))
        enter("Keep my intake", in: "jobTitle", app: app)
        app.buttons["backToWatch"].click()
        XCTAssertTrue(app.sheets.buttons["Stay"].waitForExistence(timeout: 3))
        app.sheets.buttons["Stay"].click()
        XCTAssertEqual(app.textFields["jobTitle"].value as? String, "Keep my intake")
        app.windows.firstMatch.typeKey("3", modifierFlags: [.command, .option])
        XCTAssertTrue(app.sheets.buttons["Discard"].waitForExistence(timeout: 3))
        app.sheets.buttons["Discard"].click()
        XCTAssertTrue(app.buttons["addCaliber"].waitForExistence(timeout: 5))
        openWatches(app)
        XCTAssertTrue(app.buttons["startWatchJob"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["startWatchJob"].label, "Start Job")
    }

    @MainActor
    func testIndependentConditionWaitingClosureAndReopen() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        createWatch(app)
        app.buttons["startWatchJob"].click()
        enter("Inspect movement", in: "jobTitle", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["changeJobStage"].waitForExistence(timeout: 5))
        app.buttons["changeWatchCondition"].click()
        choose("Disassembled", picker: "watchCondition", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["changeJobStage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Disassembled"].exists)
        XCTAssertTrue(app.staticTexts["Planned"].exists)
        app.buttons["changeJobStage"].click()
        choose("Waiting", picker: "jobStage", app: app)
        app.buttons["saveJobAction"].click()
        XCTAssertTrue(app.staticTexts["jobActionSaveError"].waitForExistence(timeout: 5))
        enter("Await inspection", in: "jobWaitingReason", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["changeJobStage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Disassembled"].exists)
        XCTAssertTrue(app.staticTexts["Await inspection"].exists)
        app.buttons["changeJobStage"].click()
        choose("Completed", picker: "jobStage", app: app)
        enter("Service complete", in: "jobOutcome", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["reopenJob"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editJob"].exists)
        XCTAssertFalse(app.buttons["changeWatchCondition"].exists)
        app.buttons["reopenJob"].click()
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editJob"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["In progress"].exists)
        XCTAssertTrue(app.staticTexts["Disassembled"].exists)
    }

    @MainActor
    func testTaskValidationDraftGuardClosureAndRestart() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        createWatch(app)
        app.buttons["startWatchJob"].click()
        enter("Bench repair", in: "jobTitle", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["addTask"].waitForExistence(timeout: 5))
        app.buttons["addTask"].click()
        enter("Inspect escapement", in: "taskTitle", app: app)
        enter("Inspection", in: "taskGroupLabel", app: app)
        choose("Waiting", picker: "taskStatus", app: app)
        app.buttons["saveTask"].click()
        XCTAssertTrue(app.staticTexts["taskSaveError"].waitForExistence(timeout: 5))
        enter("Need technical sheet", in: "taskWaitingReason", app: app)
        app.buttons["backFromTask"].click()
        XCTAssertTrue(app.sheets.buttons["Stay"].waitForExistence(timeout: 3))
        app.sheets.buttons["Stay"].click()
        XCTAssertEqual(app.textFields["taskTitle"].value as? String, "Inspect escapement")
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editTask"].waitForExistence(timeout: 5))
        app.buttons["backFromTask"].click()
        XCTAssertTrue(app.staticTexts["Planned"].waitForExistence(timeout: 5))
        app.buttons["changeJobStage"].click()
        choose("Completed", picker: "jobStage", app: app)
        enter("Service complete", in: "jobOutcome", app: app)
        app.buttons["saveJobAction"].click()
        XCTAssertTrue(app.staticTexts["jobActionSaveError"].waitForExistence(timeout: 5))
        enter("Owner will handle inspection", in: "jobUnfinishedTasksReason", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["reopenJob"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["addTask"].isEnabled)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["reopenJob"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Owner will handle inspection"].exists)
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "task-",
                    "Inspect escapement")
            ).count, 1)
        app.buttons["reopenJob"].click()
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["addTask"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["addTask"].isEnabled)
    }

    @MainActor
    func testTaskOrderingKeyboardDragProgressAndRestart() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        createWatch(app)
        app.buttons["startWatchJob"].click()
        enter("Bench order", in: "jobTitle", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["addTask"].waitForExistence(timeout: 5))
        let progress = app.descendants(matching: .any)["taskProgressSummary"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertEqual(progress.label, "Task progress: No tasks planned. 0 skipped.")
        for (title, status) in [("Inspect", "Done"), ("Polish", "Skipped"), ("Test", "To do")] {
            app.buttons["addTask"].click()
            enter(title, in: "taskTitle", app: app)
            enter("Testing", in: "taskGroupLabel", app: app)
            choose(status, picker: "taskStatus", app: app)
            if status == "Skipped" { enter("Outside scope", in: "taskSkippedReason", app: app) }
            app.windows.firstMatch.typeKey("s", modifierFlags: .command)
            XCTAssertTrue(app.buttons["editTask"].waitForExistence(timeout: 5))
            app.buttons["backFromTask"].click()
            XCTAssertTrue(app.buttons["addTask"].waitForExistence(timeout: 5))
        }
        XCTAssertEqual(progress.label, "Task progress: 1 of 2 tasks done, 50 percent. 1 skipped.")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-"))
        rows.element(boundBy: 0).click()
        XCTAssertTrue(app.buttons["moveTaskDown"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["moveTaskUp"].isEnabled)
        app.windows.firstMatch.typeKey(.downArrow, modifierFlags: [.command, .option])
        let upEnabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: upEnabled, object: app.buttons["moveTaskUp"])
                ], timeout: 5), .completed)
        app.buttons["backFromTask"].click()
        XCTAssertTrue(rows.element(boundBy: 0).label.contains("Polish"))
        XCTAssertTrue(rows.element(boundBy: 1).label.contains("Inspect"))
        let polishID = rows.element(boundBy: 0).identifier
        let inspectID = rows.element(boundBy: 1).identifier
        let testID = rows.element(boundBy: 2).identifier
        rows.element(boundBy: 2).scrollFullyIntoView(in: app.windows.firstMatch)
        rows.element(boundBy: 2).click(forDuration: 1, thenDragTo: rows.element(boundBy: 0))
        let testFirst = NSPredicate(format: "identifier == %@", testID)
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: testFirst, object: rows.element(boundBy: 0))
                ], timeout: 5), .completed)
        XCTAssertEqual(rows.element(boundBy: 1).identifier, polishID)
        XCTAssertEqual(rows.element(boundBy: 2).identifier, inspectID)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["addTask"].waitForExistence(timeout: 5))
        XCTAssertEqual(rows.element(boundBy: 0).identifier, testID)
        XCTAssertEqual(rows.element(boundBy: 1).identifier, polishID)
        XCTAssertEqual(rows.element(boundBy: 2).identifier, inspectID)
        rows.element(boundBy: 2).click()
        app.buttons["editTask"].click()
        choose("Doing", picker: "taskStatus", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["backFromTask"].waitForExistence(timeout: 5))
        app.buttons["backFromTask"].click()
        XCTAssertEqual(progress.label, "Task progress: 0 of 2 tasks done, 0 percent. 1 skipped.")
    }

    @MainActor
    private func choose(_ value: String, picker identifier: String, app: XCUIApplication) {
        let picker = app.popUpButtons[identifier]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.click()
        app.menuItems[value].firstMatch.click()
    }

    @MainActor
    private func isolatedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["URE_TESTING"] = "1"
        app.launchEnvironment["URE_TEST_LIBRARY_ID"] = UUID().uuidString
        app.launchArguments = ["-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        return app
    }

    @MainActor
    private func openWatches(_ app: XCUIApplication) {
        app.activate()
        XCTAssertTrue(app.outlines["Workshop sections"].waitForExistence(timeout: 5))
        app.windows.firstMatch.typeKey("2", modifierFlags: [.command, .option])
        XCTAssertTrue(app.buttons["addWatch"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func createWatch(_ app: XCUIApplication) {
        openWatches(app)
        app.buttons["addWatch"].click()
        enter("Inherited watch", in: "watchName", app: app)
        enter("000042.7-A", in: "watchSerial", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["startWatchJob"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func enter(_ text: String, in identifier: String, app: XCUIApplication) {
        let field = app.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }
}
