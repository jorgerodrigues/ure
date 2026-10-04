import Foundation
import XCTest

nonisolated final class SearchUITests: XCTestCase {
    @MainActor
    func testDuplicateNotesOpenExactJobAndSearchProtectsUnsavedDraft() {
        let app = XCUIApplication()
        app.launchEnvironment["URE_TESTING"] = "1"
        app.launchEnvironment["URE_TEST_LIBRARY_ID"] = UUID().uuidString
        app.launchArguments = ["-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }
        createNote(watch: "Search watch A", job: "Service A", body: "Finding A", app: app)
        createNote(watch: "Search watch B", job: "Service B", body: "Finding B", app: app)
        app.windows.firstMatch.typeKey("f", modifierFlags: [.command, .shift])
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("0012–å/04")
        let rowA = result(watch: "Search watch A", app: app)
        let rowB = result(watch: "Search watch B", app: app)
        XCTAssertTrue(rowA.waitForExistence(timeout: 5))
        XCTAssertTrue(rowB.waitForExistence(timeout: 5))
        rowA.click()
        XCTAssertTrue(app.buttons["editNote"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Finding A"].exists)
        app.buttons["editNote"].click()
        enter("Keep correction", identifier: "noteTitle", app: app)
        app.buttons["searchLibrary"].click()
        XCTAssertTrue(rowB.waitForExistence(timeout: 5))
        rowB.click()
        XCTAssertTrue(app.sheets.buttons["Stay"].waitForExistence(timeout: 3))
        app.sheets.buttons["Stay"].click()
        XCTAssertEqual(app.textFields["noteTitle"].value as? String, "Keep correction")
        rowB.click()
        app.sheets.buttons["Save"].click()
        XCTAssertTrue(app.buttons["editNote"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Finding B"].exists)
        app.buttons["backFromNote"].click()
        app.buttons["showJobActivity"].click()
        XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 3))
        app.buttons["searchLibrary"].click()
        XCTAssertTrue(rowB.waitForExistence(timeout: 5))
        rowB.click()
        XCTAssertTrue(app.buttons["editNote"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Finding B"].exists)
        app.buttons["searchLibrary"].click()
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
        XCTAssertTrue(app.buttons["editNote"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func result(watch: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "searchResult-Note-",
                watch)
        ).firstMatch
    }

    @MainActor
    private func createNote(watch: String, job: String, body: String, app: XCUIApplication) {
        app.windows.firstMatch.typeKey("2", modifierFlags: [.command, .option])
        XCTAssertTrue(app.buttons["addWatch"].waitForExistence(timeout: 5))
        app.buttons["addWatch"].click()
        enter(watch, identifier: "watchName", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["startWatchJob"].waitForExistence(timeout: 5))
        app.buttons["startWatchJob"].click()
        enter(job, identifier: "jobTitle", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["addNote"].waitForExistence(timeout: 5))
        app.buttons["addNote"].click()
        enter("0012–Å/04", identifier: "noteTitle", app: app)
        let editor = app.textViews["noteBody"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.click()
        editor.typeText(body)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editNote"].waitForExistence(timeout: 5))
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
