import Foundation
import XCTest

nonisolated final class TaskPartUITests: XCTestCase {
    @MainActor
    func testSavedSelectionArrivalCancellationUnlinkingAndRestart() {
        let app = XCUIApplication()
        app.launchEnvironment["URE_TESTING"] = "1"
        app.launchEnvironment["URE_TEST_LIBRARY_ID"] = UUID().uuidString
        app.launchArguments = ["-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }
        app.windows.firstMatch.typeKey("2", modifierFlags: [.command, .option])
        XCTAssertTrue(app.buttons["addWatch"].waitForExistence(timeout: 5))
        app.buttons["addWatch"].click()
        enter("Task parts watch", identifier: "watchName", app: app)
        save(app)
        XCTAssertTrue(app.buttons["startWatchJob"].waitForExistence(timeout: 5))
        app.buttons["startWatchJob"].click()
        enter("Fit setting mechanism", identifier: "jobTitle", app: app)
        save(app)
        createPart("Stem", app: app)
        createPart("Setting lever", app: app)
        app.buttons["addTask"].click()
        enter("Assemble mechanism", identifier: "taskTitle", app: app)
        app.popUpButtons["taskStatus"].click()
        app.menuItems["Waiting"].firstMatch.click()
        let choices = app.checkBoxes.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "taskPart-"))
        XCTAssertEqual(choices.count, 2)
        choices.element(boundBy: 0).click()
        choices.element(boundBy: 1).click()
        save(app)
        XCTAssertTrue(app.buttons["editTask"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["taskAvailability"].value as? String, "Waiting for parts")
        app.buttons["editTask"].click()
        choices.element(boundBy: 0).click()
        choices.element(boundBy: 1).click()
        save(app)
        XCTAssertTrue(app.staticTexts["taskSaveError"].waitForExistence(timeout: 3))
        app.buttons["cancelTask"].click()
        XCTAssertTrue(app.staticTexts["Stem"].exists && app.staticTexts["Setting lever"].exists)
        app.buttons["backFromTask"].click()
        changePart("Stem", to: "Arrived", app: app)
        changePart("Setting lever", to: "Arrived", app: app)
        let task = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-"))
            .firstMatch
        task.click()
        XCTAssertTrue(app.staticTexts["taskAvailability"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["taskAvailability"].value as? String, "Parts available")
        XCTAssertTrue(app.staticTexts["Waiting"].exists)
        app.buttons["backFromTask"].click()
        changePart("Stem", to: "Cancelled", app: app)
        task.click()
        XCTAssertEqual(app.staticTexts["taskAvailability"].value as? String, "Needs review")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["addTask"].waitForExistence(timeout: 5))
        task.click()
        XCTAssertEqual(app.staticTexts["taskAvailability"].value as? String, "Needs review")
        XCTAssertTrue(app.staticTexts["Waiting"].exists)
        app.buttons["editTask"].click()
        choices.element(boundBy: 0).click()
        choices.element(boundBy: 1).click()
        app.popUpButtons["taskStatus"].click()
        app.menuItems["Doing"].firstMatch.click()
        save(app)
        XCTAssertTrue(app.buttons["editTask"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["taskAvailability"].exists)
        XCTAssertTrue(app.staticTexts["Doing"].exists)
    }

    @MainActor
    private func createPart(_ name: String, app: XCUIApplication) {
        XCTAssertTrue(app.buttons["addPart"].waitForExistence(timeout: 5))
        app.buttons["addPart"].click()
        enter(name, identifier: "partDescription", app: app)
        save(app)
        XCTAssertTrue(app.buttons["editPart"].waitForExistence(timeout: 5))
        app.buttons["backFromPart"].click()
    }

    @MainActor
    private func changePart(_ name: String, to status: String, app: XCUIApplication) {
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "part-", name)
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        app.buttons["editPart"].click()
        app.popUpButtons["partStatus"].click()
        app.menuItems[status].firstMatch.click()
        if status == "Cancelled" { enter("Wrong part", identifier: "partStatusReason", app: app) }
        save(app)
        XCTAssertTrue(app.buttons["editPart"].waitForExistence(timeout: 5))
        app.buttons["backFromPart"].click()
    }

    @MainActor
    private func save(_ app: XCUIApplication) {
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
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
