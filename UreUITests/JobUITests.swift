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
    func testReferenceWindowIsReadOnlyAndLeavesTheMainPageAsItIs() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        createWatch(app)
        startJob("Bench repair", app: app)
        let notes = app.textViews["recordNotes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.click()
        notes.typeText("Half-typed finding")
        let main = app.windows.firstMatch
        main.typeKey("r", modifierFlags: [.command, .option])
        let reference = app.windows["Reference"]
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        XCTAssertTrue(reference.staticTexts["No pinned reference"].exists)
        XCTAssertEqual(reference.textViews.count, 0)
        // The record commands belong to the main window, so they change nothing from here.
        reference.typeKey("s", modifierFlags: .command)
        reference.typeKey("n", modifierFlags: .command)
        reference.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.textFields["jobTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["jobTitle"].value as? String, "Bench repair")
        XCTAssertEqual(app.textViews["recordNotes"].value as? String, "Half-typed finding")
    }

    @MainActor
    func testAChecklistIsTypedWithTheKeyboardAloneAndKeepsItsOrder() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        createWatch(app)
        startJob("Full service", app: app)
        let add = app.textFields.matching(NSPredicate(format: "label == %@", "Add a step"))
            .firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()
        for line in ["Clean all parts", "# Assembly", "Fit the new mainspring"] {
            window.typeText(line)
            window.typeKey(.return, modifierFlags: [])
        }
        window.typeText("Oil the escapement")
        window.typeKey("u", modifierFlags: [.command, .shift])
        window.typeKey(.upArrow, modifierFlags: [.command, .control])
        let progress = app.descendants(matching: .any)["checklistProgress"].firstMatch
        XCTAssertEqual(progress.value as? String, "1 of 3 steps done")
        XCTAssertEqual(
            lines(app),
            [
                "Clean all parts", "Assembly", "Oil the escapement", "Fit the new mainspring",
            ])
        capture(app, name: "Checklist-typed")
        // Undo puts back the order, then the tick.
        window.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(lines(app).last, "Oil the escapement")
        window.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(progress.value as? String, "0 of 3 steps done")
        window.typeKey("z", modifierFlags: [.command, .shift])
        window.typeKey("z", modifierFlags: [.command, .shift])
        window.typeKey(.tab, modifierFlags: [])
        app.terminate()
        app.launch()
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertEqual(progress.value as? String, "1 of 3 steps done")
        XCTAssertEqual(
            lines(app),
            [
                "Clean all parts", "Assembly", "Oil the escapement", "Fit the new mainspring",
            ])
    }

    // The checklist's lines from top to bottom, without the row that adds a step.
    @MainActor
    private func lines(_ app: XCUIApplication) -> [String] {
        app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "checklistStep-"))
            .allElementsBoundByIndex
            .filter { $0.label != "Add a step" }
            .sorted { $0.frame.minY < $1.frame.minY }
            .compactMap { $0.value as? String }
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
