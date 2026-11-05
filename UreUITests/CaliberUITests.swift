import Foundation
import XCTest

nonisolated final class CaliberUITests: XCTestCase {
    @MainActor
    func testCaliberFactsSaveInPlaceAndReachLinkedWatchesAfterRestart() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        openSection("3", control: "addCaliber", app: app)
        let window = app.windows.firstMatch
        window.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textFields["caliberName"].waitForExistence(timeout: 5))
        window.typeText("Fixture 0012")
        window.typeKey(.tab, modifierFlags: [])
        window.typeText("Example maker")
        window.typeKey(.return, modifierFlags: [])
        window.typeText("18000")
        window.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(app.textFields["caliberBeatRate"].value as? String, "18,000 vph")
        app.menuButtons["caliberWinding"].click()
        app.menuItems["Manual"].click()
        XCTAssertEqual(app.menuButtons["caliberWinding"].value as? String, "Manual")
        createWatch("First watch", caliber: "Example maker Fixture 0012", app: app)
        createWatch("Second watch", caliber: "Example maker Fixture 0012", app: app)
        openSection("3", control: "addCaliber", app: app)
        app.staticTexts["Example maker Fixture 0012"].firstMatch.click()
        XCTAssertTrue(app.buttons["First watch"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Second watch"].exists)
        enter("Corrected fixture", in: "caliberName", app: app)
        window.typeKey(.tab, modifierFlags: [])
        app.buttons["First watch"].click()
        XCTAssertTrue(app.staticTexts["Corrected fixture"].waitForExistence(timeout: 5))
        app.buttons["editWatch"].click()
        chooseCaliber("Unknown", app: app)
        window.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editWatch"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        openSection("3", control: "addCaliber", app: app)
        app.staticTexts["Example maker Corrected fixture"].firstMatch.click()
        XCTAssertTrue(app.textFields["caliberName"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["caliberName"].value as? String, "Corrected fixture")
        XCTAssertEqual(app.textFields["caliberBeatRate"].value as? String, "18,000 vph")
        XCTAssertFalse(app.buttons["First watch"].exists)
        XCTAssertTrue(app.buttons["Second watch"].exists)
        capture(app, name: "Caliber-facts-after-restart")
    }

    @MainActor
    func testInvalidNumberStaysOnThePageAndLeavingDoesNotAsk() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        openSection("3", control: "addCaliber", app: app)
        let window = app.windows.firstMatch
        window.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textFields["caliberName"].waitForExistence(timeout: 5))
        window.typeText("Draft caliber")
        enter("0", in: "caliberBeatRate", app: app)
        window.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Enter a beat rate'"))
                .firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["caliberBeatRate"].value as? String, "0")
        window.typeKey("2", modifierFlags: [.command, .option])
        XCTAssertFalse(app.sheets.buttons["Stay"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["No watches"].waitForExistence(timeout: 5))
        openSection("3", control: "addCaliber", app: app)
        app.staticTexts["Draft caliber"].firstMatch.click()
        XCTAssertTrue(app.textFields["caliberBeatRate"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["caliberBeatRate"].value as? String, "0")
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
    private func openSection(_ shortcut: String, control: String, app: XCUIApplication) {
        app.activate()
        XCTAssertTrue(app.outlines["Workshop sections"].waitForExistence(timeout: 5))
        app.windows.firstMatch.typeKey(shortcut, modifierFlags: [.command, .option])
        XCTAssertTrue(app.buttons[control].waitForExistence(timeout: 5))
    }

    @MainActor
    private func createWatch(_ name: String, caliber: String, app: XCUIApplication) {
        openSection("2", control: "addWatch", app: app)
        app.buttons["addWatch"].click()
        enter(name, in: "watchName", app: app)
        chooseCaliber(caliber, app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editWatch"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func chooseCaliber(_ label: String, app: XCUIApplication) {
        app.popUpButtons["watchCaliber"].click()
        app.menuItems[label].click()
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
