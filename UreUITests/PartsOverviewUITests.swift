import Foundation
import XCTest

nonisolated final class PartsOverviewUITests: XCTestCase {
    @MainActor
    func testSimilarPartsOpenTheirJobsAndCommittedStatusRefreshesBothLists() {
        let app = XCUIApplication()
        app.launchEnvironment["URE_TESTING"] = "1"
        app.launchEnvironment["URE_TEST_LIBRARY_ID"] = UUID().uuidString
        app.launchArguments = ["-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }
        createPart(watch: "Parts watch A", job: "Service A", reference: "0012-A", app: app)
        createPart(watch: "Parts watch B", job: "Service B", reference: "0012-B", app: app)
        app.windows.firstMatch.typeKey("4", modifierFlags: [.command, .option])
        let rowA = overviewRow(watch: "Parts watch A", app: app)
        let rowB = overviewRow(watch: "Parts watch B", app: app)
        XCTAssertTrue(rowA.waitForExistence(timeout: 5))
        XCTAssertTrue(rowB.waitForExistence(timeout: 5))
        rowA.click()
        XCTAssertTrue(app.buttons["editPart"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0012-A"].exists)
        app.buttons["backToWatch"].click()
        XCTAssertTrue(app.buttons["editWatch"].waitForExistence(timeout: 3))
        rowA.click()
        XCTAssertTrue(app.buttons["editPart"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["0012-A"].exists)
        app.buttons["editPart"].click()
        app.popUpButtons["partStatus"].click()
        app.menuItems["Arrived"].firstMatch.click()
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editPart"].waitForExistence(timeout: 5))
        app.popUpButtons["partsStatusFilter"].click()
        app.menuItems["Needed"].firstMatch.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["partsSelectionMessage"].waitForExistence(timeout: 3))
        XCTAssertFalse(rowA.exists)
        XCTAssertTrue(rowB.exists)
        rowB.click()
        XCTAssertTrue(app.staticTexts["0012-B"].waitForExistence(timeout: 3))
        app.buttons["editPart"].click()
        enter("Keep my draft", identifier: "partDescription", app: app)
        app.windows.firstMatch.typeKey("2", modifierFlags: [.command, .option])
        XCTAssertTrue(app.sheets.buttons["Stay"].waitForExistence(timeout: 3))
        app.sheets.buttons["Stay"].click()
        XCTAssertEqual(app.textFields["partDescription"].value as? String, "Keep my draft")
        app.buttons["cancelPart"].click()
        app.popUpButtons["partsStatusFilter"].click()
        app.menuItems["Installed"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["No matching parts"].waitForExistence(timeout: 3))
        app.buttons["Clear Filters"].firstMatch.click()
        XCTAssertTrue(rowA.waitForExistence(timeout: 3))
        rowA.click()
        app.buttons["backFromPart"].click()
        XCTAssertTrue(app.staticTexts["Service A"].waitForExistence(timeout: 3))
        let jobPart = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "part-")
        ).firstMatch
        XCTAssertTrue(jobPart.waitForExistence(timeout: 3))
        XCTAssertTrue(jobPart.label.contains("Arrived"))
        app.buttons["showJobActivity"].click()
        XCTAssertTrue(app.staticTexts["Activity"].waitForExistence(timeout: 3))
        rowA.click()
        XCTAssertTrue(app.buttons["editPart"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["0012-A"].exists)
        app.buttons["backFromPart"].click()
        app.buttons["changeJobStage"].click()
        app.popUpButtons["jobStage"].click()
        app.menuItems["Completed"].firstMatch.click()
        enter("Reviewed", identifier: "jobOutcome", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["reopenJob"].waitForExistence(timeout: 5))
        XCTAssertFalse(rowA.exists)
        XCTAssertTrue(rowB.exists)
        app.buttons["backToWatch"].click()
        XCTAssertTrue(app.staticTexts["Parts watch A"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func overviewRow(watch: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND value CONTAINS %@", "overviewPart-", watch)
        ).firstMatch
    }

    @MainActor
    private func createPart(watch: String, job: String, reference: String, app: XCUIApplication) {
        app.windows.firstMatch.typeKey("2", modifierFlags: [.command, .option])
        XCTAssertTrue(app.buttons["addWatch"].waitForExistence(timeout: 5))
        app.buttons["addWatch"].click()
        enter(watch, identifier: "watchName", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["startWatchJob"].waitForExistence(timeout: 5))
        app.buttons["startWatchJob"].click()
        enter(job, identifier: "jobTitle", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["addPart"].waitForExistence(timeout: 5))
        app.buttons["addPart"].click()
        enter("Mainspring", identifier: "partDescription", app: app)
        enter(reference, identifier: "partManufacturerReference", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editPart"].waitForExistence(timeout: 5))
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
