import Foundation
import XCTest

nonisolated final class JobUITests: XCTestCase {
    @MainActor
    func testAStartedJobPutsTheCursorInItsTitleAndSavesInPlace() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        createWatch(app)
        app.buttons["startWatchJob"].click()
        let title = app.textFields["jobTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "New Job")
        XCTAssertEqual(state(app).value as? String, "In progress")
        window.typeText("Full service")
        let problem = app.textViews["jobProblem"]
        problem.click()
        problem.typeText("Loses about two minutes a day.")
        window.typeKey(.tab, modifierFlags: [])
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["jobTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["jobTitle"].value as? String, "Full service")
        XCTAssertEqual(
            app.textViews["jobProblem"].value as? String, "Loses about two minutes a day.")
        XCTAssertTrue(app.buttons["jobWatch"].exists)
        app.buttons["jobWatch"].click()
        XCTAssertTrue(app.buttons["watchOpenJob"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["startWatchJob"].exists)
        capture(app, name: "Watch-with-open-job")
    }

    @MainActor
    func testTheStatePopUpSavesAndUndoPutsBackTheStateBefore() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        createWatch(app)
        startJob("Full service", app: app)
        chooseState("Waiting", app: app)
        let waiting = app.textFields["jobWaitingFor"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 5))
        window.typeText("a mainspring")
        window.typeKey(.tab, modifierFlags: [])
        chooseState("Done", app: app)
        XCTAssertFalse(app.textFields["jobWaitingFor"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' · Done '")).firstMatch
                .waitForExistence(timeout: 5))
        window.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.textFields["jobWaitingFor"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["jobWaitingFor"].value as? String, "a mainspring")
        XCTAssertEqual(state(app).value as? String, "Waiting")
        window.typeKey("z", modifierFlags: [.command, .shift])
        let done = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'Done'"), object: state(app))
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 5), .completed)
        enter("Full service and crystal", in: "jobTitle", app: app)
        window.typeKey(.return, modifierFlags: [])
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["jobTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["jobTitle"].value as? String, "Full service and crystal")
        XCTAssertEqual(state(app).value as? String, "Done")
        capture(app, name: "Done-job")
    }

    @MainActor
    func testReferenceWindowDoesNotSaveOrReplaceTheMainDraft() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        createWatch(app)
        startJob("Bench repair", app: app)
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
    func testTaskValidationDraftGuardDoneJobAndRestart() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        createWatch(app)
        startJob("Bench repair", app: app)
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
        chooseState("Done", app: app)
        XCTAssertTrue(app.buttons["addTask"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["addTask"].isEnabled)
        app.terminate()
        app.launch()
        XCTAssertTrue(state(app).waitForExistence(timeout: 5))
        XCTAssertEqual(state(app).value as? String, "Done")
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "task-",
                    "Inspect escapement")
            ).count, 1)
        XCTAssertTrue(app.buttons["addTask"].isEnabled)
    }

    @MainActor
    func testTaskOrderingKeyboardDragProgressAndRestart() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        createWatch(app)
        startJob("Bench order", app: app)
        XCTAssertTrue(app.buttons["addTask"].waitForExistence(timeout: 5))
        let progress = app.descendants(matching: .any)["taskProgressSummary"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertEqual(progress.value as? String, "No tasks planned. 0 skipped.")
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
        XCTAssertEqual(progress.value as? String, "1 of 2 tasks done, 50 percent. 1 skipped.")
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
        XCTAssertEqual(progress.value as? String, "0 of 2 tasks done, 0 percent. 1 skipped.")
    }

    @MainActor
    private func choose(_ value: String, picker identifier: String, app: XCUIApplication) {
        let picker = app.popUpButtons[identifier]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.click()
        app.menuItems[value].firstMatch.click()
    }

    // Starts a job from the watch page and types its title over "New Job".
    @MainActor
    private func startJob(_ title: String, app: XCUIApplication) {
        app.buttons["startWatchJob"].click()
        XCTAssertTrue(app.textFields["jobTitle"].waitForExistence(timeout: 5))
        app.windows.firstMatch.typeText(title)
        app.windows.firstMatch.typeKey(.return, modifierFlags: [])
    }

    @MainActor
    private func state(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["jobState"].firstMatch
    }

    @MainActor
    private func chooseState(_ value: String, app: XCUIApplication) {
        XCTAssertTrue(state(app).waitForExistence(timeout: 3))
        state(app).click()
        app.menuItems[value].firstMatch.click()
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
        app.windows.firstMatch.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["newRecord"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func createWatch(_ app: XCUIApplication) {
        openWatches(app)
        app.buttons["newRecord"].click()
        enter("Inherited watch", in: "watchName", app: app)
        enter("000042.7-A", in: "watchSerial", app: app)
        app.windows.firstMatch.typeKey(.return, modifierFlags: [])
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
