import Foundation
import XCTest

nonisolated final class ArchiveUITests: XCTestCase {
    @MainActor
    func testArchiveAWatchWithAnOpenJobUndoAndUnarchive() {
        let app = XCUIApplication()
        app.launchEnvironment["URE_TESTING"] = "1"
        app.launchEnvironment["URE_TEST_LIBRARY_ID"] = UUID().uuidString
        app.launchArguments = ["-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        window.typeKey("2", modifierFlags: [.command, .option])
        XCTAssertTrue(app.buttons["addWatch"].waitForExistence(timeout: 5))
        app.buttons["addWatch"].click()
        let name = app.textFields["watchName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Archive fixture")
        window.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["startWatchJob"].waitForExistence(timeout: 5))
        app.buttons["startWatchJob"].click()
        let title = app.textFields["jobTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.typeText("Full service")
        window.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["backToWatch"].waitForExistence(timeout: 5))
        app.buttons["backToWatch"].click()
        XCTAssertTrue(app.buttons["watchOpenJob"].waitForExistence(timeout: 5))

        app.menuBars.menuBarItems["Record"].click()
        app.menuItems["Archive Watch"].click()
        XCTAssertTrue(app.buttons["unarchiveWatch"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Hidden from Watches. Still in search."].exists)
        XCTAssertTrue(app.buttons["archivedWatches"].exists)
        window.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.buttons["watchOpenJob"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["archivedWatches"].exists)

        app.staticTexts["Archive fixture"].firstMatch.rightClick()
        app.menuItems["Archive Watch"].click()
        XCTAssertTrue(app.buttons["unarchiveWatch"].waitForExistence(timeout: 5))
        window.typeKey("1", modifierFlags: [.command, .option])
        XCTAssertTrue(app.staticTexts["Full service"].firstMatch.waitForExistence(timeout: 5))
        window.typeKey("2", modifierFlags: [.command, .option])
        app.staticTexts["Archive fixture"].firstMatch.click()
        XCTAssertTrue(app.buttons["unarchiveWatch"].waitForExistence(timeout: 5))
        app.buttons["unarchiveWatch"].click()
        XCTAssertTrue(app.buttons["watchOpenJob"].waitForExistence(timeout: 5))
    }
}
