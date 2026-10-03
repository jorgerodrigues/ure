import Foundation
import XCTest

nonisolated final class ArchiveUITests: XCTestCase {
    @MainActor
    func testArchiveUnarchiveAndConfirmedNoteRemoval() {
        let app = XCUIApplication()
        app.launchEnvironment["URE_TESTING"] = "1"
        app.launchEnvironment["URE_TEST_LIBRARY_ID"] = UUID().uuidString
        app.launchArguments = ["-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }
        app.windows.firstMatch.typeKey("2", modifierFlags: [.command, .option])
        XCTAssertTrue(app.buttons["addWatch"].waitForExistence(timeout: 5))
        app.buttons["addWatch"].click()
        let name = app.textFields["watchName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("Archive fixture")
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["archiveWatch"].waitForExistence(timeout: 5))
        app.buttons["archiveWatch"].click()
        XCTAssertTrue(app.buttons["editWatch"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editWatch"].isEnabled)
        XCTAssertFalse(app.buttons["startWatchJob"].isEnabled)
        app.windows.firstMatch.typeKey("5", modifierFlags: [.command, .option])
        XCTAssertTrue(app.outlines["archiveList"].waitForExistence(timeout: 5))
        app.staticTexts["Archive fixture"].firstMatch.click()
        XCTAssertTrue(app.buttons["archiveWatch"].waitForExistence(timeout: 5))
        app.buttons["archiveWatch"].click()
        XCTAssertTrue(app.buttons["addNote"].waitForExistence(timeout: 5))
        app.buttons["addNote"].click()
        let title = app.textFields["noteTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click()
        title.typeText("Remove fixture note")
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["removeNote"].waitForExistence(timeout: 5))
        app.buttons["removeNote"].click()
        XCTAssertTrue(app.sheets.buttons["Cancel"].waitForExistence(timeout: 5))
        app.sheets.buttons["Cancel"].click()
        XCTAssertTrue(app.staticTexts["Remove fixture note"].exists)
        app.buttons["removeNote"].click()
        XCTAssertTrue(app.sheets.buttons["Remove"].waitForExistence(timeout: 5))
        app.sheets.buttons["Remove"].click()
        XCTAssertTrue(app.buttons["addNote"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["removeNote"].exists)
    }
}
