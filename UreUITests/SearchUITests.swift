import Foundation
import XCTest

nonisolated final class SearchUITests: XCTestCase {
    @MainActor
    func testSearchFindsTheExactJobFromItsNotesAndSaysWhenNothingMatches() {
        let app = XCUIApplication()
        app.launchEnvironment["URE_TESTING"] = "1"
        app.launchEnvironment["URE_TEST_LIBRARY_ID"] = UUID().uuidString
        app.launchArguments = ["-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }
        createJob(watch: "Search watch A", job: "Service A", notes: "Finding A 0012–Å/04", app: app)
        createJob(watch: "Search watch B", job: "Service B", notes: "Finding B 0012–Å/04", app: app)
        let window = app.windows.firstMatch
        window.typeKey("f", modifierFlags: [.command, .shift])
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("0012–å/04")
        let rowA = result(watch: "Search watch A", app: app)
        let rowB = result(watch: "Search watch B", app: app)
        XCTAssertTrue(rowA.waitForExistence(timeout: 5))
        XCTAssertTrue(rowB.waitForExistence(timeout: 5))
        rowA.click()
        XCTAssertTrue(app.textFields["jobTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["jobTitle"].value as? String, "Service A")
        XCTAssertTrue(notes(app).contains("Finding A"))
        window.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(rowB.waitForExistence(timeout: 5))
        rowB.click()
        XCTAssertTrue(app.textFields["jobTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["jobTitle"].value as? String, "Service B")
        XCTAssertTrue(notes(app).contains("Finding B"))
        window.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("No matching record")
        let noResults = app.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH %@", "No Results for")
        ).firstMatch
        XCTAssertTrue(noResults.waitForExistence(timeout: 5))
        XCTAssertTrue((noResults.value as? String)?.contains("No matching record") == true)
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "searchResult-"))
                .count, 0)
        app.buttons["closeGlobalSearch"].click()
        XCTAssertTrue(app.textFields["jobTitle"].waitForExistence(timeout: 5))
    }

    // A job found by its notes, whose row names its watch.
    @MainActor
    private func result(watch: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "searchResult-Job-",
                watch)
        ).firstMatch
    }

    @MainActor
    private func notes(_ app: XCUIApplication) -> String {
        let notes = app.textViews["recordNotes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 3))
        return notes.value as? String ?? ""
    }

    // A new watch with a job whose notes are typed in place. The notes save as you type.
    @MainActor
    private func createJob(watch: String, job: String, notes: String, app: XCUIApplication) {
        app.windows.firstMatch.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["newRecord"].waitForExistence(timeout: 5))
        app.buttons["newRecord"].click()
        enter(watch, identifier: "watchName", app: app)
        app.windows.firstMatch.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["startWatchJob"].waitForExistence(timeout: 5))
        app.buttons["startWatchJob"].click()
        enter(job, identifier: "jobTitle", app: app)
        app.windows.firstMatch.typeKey(.return, modifierFlags: [])
        let editor = app.textViews["recordNotes"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.click()
        editor.typeText(notes)
        app.textFields["jobTitle"].click()
    }

    @MainActor
    private func enter(_ value: String, identifier: String, app: XCUIApplication) {
        let field = app.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
    }
}
