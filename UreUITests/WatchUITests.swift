import Foundation
import XCTest

nonisolated final class WatchUITests: XCTestCase {
    @MainActor
    func testKeyboardCreateEditCancelAndStayWithLongName() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(app.outlines["Workshop sections"].waitForExistence(timeout: 5))
        window.typeKey("2", modifierFlags: [.command, .option])
        XCTAssertTrue(app.buttons["addWatch"].waitForExistence(timeout: 5))
        window.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textFields["watchName"].waitForExistence(timeout: 3))
        let name =
            "Long bench watch – 00042-A/7 – Å時計 – "
            + String(repeating: "Service history ", count: 10)
        window.typeText(name)
        window.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editWatch"].waitForExistence(timeout: 5))
        window.typeKey("e", modifierFlags: [.command, .option])
        XCTAssertTrue(app.textFields["watchName"].waitForExistence(timeout: 3))
        window.typeKey("a", modifierFlags: .command)
        window.typeText("Discard this edit")
        window.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 3))
        window.typeText("Search while editing")
        window.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertEqual(app.textFields["watchName"].value as? String, "Discard this edit")
        window.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editWatch"].waitForExistence(timeout: 3))
        window.typeKey("2", modifierFlags: [.command, .option])
        window.typeKey("e", modifierFlags: [.command, .option])
        XCTAssertTrue(app.textFields["watchName"].waitForExistence(timeout: 3))
        XCTAssertEqual(
            app.textFields["watchName"].value as? String, name.trimmingCharacters(in: .whitespaces))
        window.typeKey("a", modifierFlags: .command)
        window.typeText("Stay with this draft")
        window.typeKey("3", modifierFlags: [.command, .option])
        XCTAssertTrue(app.sheets.buttons["Stay"].waitForExistence(timeout: 3))
        app.sheets.firstMatch.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertEqual(app.textFields["watchName"].value as? String, "Stay with this draft")
        window.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editWatch"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testCreateEditCancelAndRestart() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        openWatches(app)
        XCTAssertTrue(app.staticTexts["No watches"].waitForExistence(timeout: 5))
        app.buttons["addWatch"].click()
        enter("Bench watch", in: "watchName", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editWatch"].waitForExistence(timeout: 5))
        app.buttons["editWatch"].click()
        enter("Renamed watch", in: "watchName", app: app)
        enter("00042-A/7", in: "watchSerial", app: app)
        enter("0", in: "watchCaseDiameter", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["watchSaveError"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["watchName"].value as? String, "Renamed watch")
        enter("36.5", in: "watchCaseDiameter", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editWatch"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["00042-A/7"].exists)
        app.buttons["editWatch"].click()
        enter("Discarded name", in: "watchName", app: app)
        app.buttons["cancelWatch"].click()
        XCTAssertTrue(app.buttons["editWatch"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Discarded name"].exists)
        app.terminate()
        app.launch()
        openWatches(app)
        let row = app.staticTexts["Renamed watch"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        XCTAssertTrue(app.buttons["editWatch"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["00042-A/7"].exists)
        capture(app, name: "Watch-after-restart")
    }

    @MainActor
    func testDirtySectionNavigationSupportsStaySaveAndDiscard() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        openWatches(app)
        app.buttons["addWatch"].click()
        enter("Unsaved watch", in: "watchName", app: app)
        app.windows.firstMatch.typeKey("3", modifierFlags: [.command, .option])
        XCTAssertTrue(app.sheets.buttons["Stay"].waitForExistence(timeout: 3))
        app.sheets.buttons["Stay"].click()
        XCTAssertEqual(app.textFields["watchName"].value as? String, "Unsaved watch")
        app.windows.firstMatch.typeKey("3", modifierFlags: [.command, .option])
        XCTAssertTrue(app.sheets.buttons["Discard"].waitForExistence(timeout: 3))
        app.sheets.buttons["Discard"].click()
        XCTAssertTrue(app.staticTexts["No calibers"].waitForExistence(timeout: 3))
        openWatches(app)
        XCTAssertTrue(app.staticTexts["No watches"].waitForExistence(timeout: 3))
        app.buttons["addWatch"].click()
        enter("Saved on navigation", in: "watchName", app: app)
        app.windows.firstMatch.typeKey("3", modifierFlags: [.command, .option])
        XCTAssertTrue(app.sheets.buttons["Stay"].waitForExistence(timeout: 3))
        app.sheets.buttons["Save"].click()
        XCTAssertTrue(app.staticTexts["No calibers"].waitForExistence(timeout: 5))
        openWatches(app)
        XCTAssertTrue(
            app.staticTexts["Saved on navigation"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testDirtyWindowCloseAndQuitKeepTheDraftWhenCancelled() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        openWatches(app)
        app.buttons["addWatch"].click()
        enter("Do not lose this", in: "watchName", app: app)
        app.windows.firstMatch.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.sheets.buttons["Stay"].waitForExistence(timeout: 3))
        app.sheets.buttons["Stay"].click()
        XCTAssertEqual(app.textFields["watchName"].value as? String, "Do not lose this")
        app.windows.firstMatch.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.sheets.buttons["Stay"].waitForExistence(timeout: 3))
        app.sheets.buttons["Stay"].click()
        XCTAssertEqual(app.textFields["watchName"].value as? String, "Do not lose this")
        capture(app, name: "Watch-unsaved-draft")
        app.windows.firstMatch.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.sheets.buttons["Discard"].waitForExistence(timeout: 3))
        app.sheets.buttons["Discard"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    @MainActor
    private func isolatedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["URE_TESTING"] = "1"
        app.launchEnvironment["URE_TEST_LIBRARY_ID"] = UUID().uuidString
        app.launchArguments = [
            "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES",
        ]
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
    private func enter(_ text: String, in identifier: String, app: XCUIApplication) {
        let field = app.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
