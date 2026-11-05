import Foundation
import XCTest

nonisolated final class WatchUITests: XCTestCase {
    @MainActor
    func testNewWatchPutsTheCursorInItsNameAndFactsSaveInPlace() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        openWatches(app)
        window.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textFields["watchName"].waitForExistence(timeout: 3))
        let name =
            "Long bench watch – 00042-A/7 – Å時計 – "
            + String(repeating: "Service history ", count: 10)
        window.typeText(name)
        window.typeKey(.tab, modifierFlags: [])
        window.typeText("Omega")
        window.typeKey(.return, modifierFlags: [])
        window.typeText("Seamaster")
        enter("00042-A/7", in: "watchSerial", app: app)
        enter("35mm", in: "watchDiameter", app: app)
        window.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(app.textFields["watchDiameter"].value as? String, "35 mm")
        enter("Ana Ribeiro", in: "watchOwner", app: app)
        enter("+351 912 480 117", in: "watchContact", app: app)
        window.typeKey(.return, modifierFlags: [])
        app.terminate()
        app.launch()
        openWatches(app)
        let row = app.staticTexts["Omega"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        XCTAssertTrue(app.textFields["watchName"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.textFields["watchName"].value as? String, name.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(app.textFields["watchSerial"].value as? String, "00042-A/7")
        XCTAssertEqual(app.textFields["watchOwner"].value as? String, "Ana Ribeiro")
        capture(app, name: "Watch-after-restart")
    }

    @MainActor
    func testInvalidDiameterStaysOnThePageAndUndoBringsBackAFact() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        openWatches(app)
        window.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textFields["watchName"].waitForExistence(timeout: 3))
        window.typeText("Bench watch")
        enter("0", in: "watchDiameter", app: app)
        window.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Enter a diameter'"))
                .firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["watchDiameter"].value as? String, "0")
        enter("Ana", in: "watchOwner", app: app)
        window.typeKey(.tab, modifierFlags: [])
        window.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(app.textFields["watchOwner"].value as? String, "")
        window.typeKey("4", modifierFlags: .command)
        XCTAssertFalse(app.sheets.buttons["Stay"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testQuitSavesTypingWithoutAsking() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        openWatches(app)
        app.buttons["newRecord"].click()
        enter("Do not lose this", in: "watchName", app: app)
        app.windows.firstMatch.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launch()
        openWatches(app)
        XCTAssertTrue(
            app.staticTexts["Do not lose this"].firstMatch.waitForExistence(timeout: 5))
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
        app.windows.firstMatch.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["newRecord"].waitForExistence(timeout: 5))
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
