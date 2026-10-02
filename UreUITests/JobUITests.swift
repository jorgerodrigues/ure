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
        openWatches(app)
        app.staticTexts["Renamed watch"].firstMatch.click()
        XCTAssertTrue(app.buttons["startWatchJob"].waitForExistence(timeout: 5))
        app.buttons["startWatchJob"].click()
        XCTAssertTrue(app.buttons["editJob"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Inspect movement"].exists)
        XCTAssertTrue(app.staticTexts["000042.7-A"].exists)
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
