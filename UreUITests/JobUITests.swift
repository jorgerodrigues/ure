import Foundation
import XCTest

nonisolated final class JobUITests: XCTestCase {
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
        app.menuItems["Job · Link · Bench sheet"].click()
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
