import Foundation
import XCTest

nonisolated final class CaliberUITests: XCTestCase {
    @MainActor
    func testSharedCaliberEditingLinkClearingAndRestart() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        openSection("3", control: "addCaliber", app: app)
        app.buttons["addCaliber"].click()
        enter("Fixture 0012", in: "caliberDesignation", app: app)
        enter("A/2", in: "caliberVariant", app: app)
        enter("Synthetic sheet for this variant", in: "caliberSourceNote", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editCaliber"].waitForExistence(timeout: 5))
        createWatch("First watch", caliber: "Fixture 0012 · A/2", app: app)
        createWatch("Second watch", caliber: "Fixture 0012 · A/2", app: app)
        openSection("3", control: "addCaliber", app: app)
        app.staticTexts["Fixture 0012 · A/2"].firstMatch.click()
        XCTAssertTrue(app.buttons["editCaliber"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["First watch"].exists)
        XCTAssertTrue(app.buttons["Second watch"].exists)
        app.buttons["editCaliber"].click()
        enter("Corrected fixture", in: "caliberDesignation", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editCaliber"].waitForExistence(timeout: 5))
        app.buttons["First watch"].click()
        XCTAssertTrue(app.staticTexts["Corrected fixture"].waitForExistence(timeout: 5))
        app.buttons["editWatch"].click()
        chooseCaliber("Unknown", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editWatch"].waitForExistence(timeout: 5))
        app.staticTexts["Second watch"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Corrected fixture"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        openSection("3", control: "addCaliber", app: app)
        app.staticTexts["Corrected fixture · A/2"].firstMatch.click()
        XCTAssertTrue(app.buttons["editCaliber"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["First watch"].exists)
        XCTAssertTrue(app.buttons["Second watch"].exists)
        capture(app, name: "Shared-caliber-after-restart")
    }

    @MainActor
    func testInvalidCaliberKeepsDraftAndDirtyNavigationSupportsStayAndDiscard() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        openSection("3", control: "addCaliber", app: app)
        app.windows.firstMatch.typeKey("n", modifierFlags: .command)
        enter("Draft caliber", in: "caliberDesignation", app: app)
        enter("0", in: "caliberBeatRate", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["caliberSaveError"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["caliberDesignation"].value as? String, "Draft caliber")
        app.windows.firstMatch.typeKey("2", modifierFlags: [.command, .option])
        XCTAssertTrue(app.sheets.buttons["Stay"].waitForExistence(timeout: 3))
        app.sheets.buttons["Stay"].click()
        XCTAssertEqual(app.textFields["caliberBeatRate"].value as? String, "0")
        app.windows.firstMatch.typeKey("2", modifierFlags: [.command, .option])
        XCTAssertTrue(app.sheets.buttons["Discard"].waitForExistence(timeout: 3))
        app.sheets.buttons["Discard"].click()
        XCTAssertTrue(app.staticTexts["No watches"].waitForExistence(timeout: 5))
        openSection("3", control: "addCaliber", app: app)
        XCTAssertTrue(app.staticTexts["No calibers"].waitForExistence(timeout: 5))
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
