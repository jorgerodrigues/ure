import XCTest

nonisolated final class PartUITests: XCTestCase {
    @MainActor
    func testURLOnlyPartsValidationDraftGuardRestartAndClosedJob() {
        let app = XCUIApplication()
        app.launchEnvironment["URE_TESTING"] = "1"
        app.launchEnvironment["URE_TEST_LIBRARY_ID"] = UUID().uuidString
        app.launchArguments = ["-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }
        app.windows.firstMatch.typeKey("2", modifierFlags: [.command, .option])
        XCTAssertTrue(app.buttons["addWatch"].waitForExistence(timeout: 5))
        app.buttons["addWatch"].click()
        enter("Parts watch", identifier: "watchName", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["startWatchJob"].waitForExistence(timeout: 5))
        app.buttons["startWatchJob"].click()
        enter("Restore movement", identifier: "jobTitle", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["addPart"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No parts required."].exists)
        app.buttons["addPart"].click()
        enter("Setting lever spring", identifier: "partDescription", app: app)
        enter("0", identifier: "partQuantity", app: app)
        app.buttons["savePart"].click()
        XCTAssertTrue(app.staticTexts["partSaveError"].waitForExistence(timeout: 3))
        enter("2", identifier: "partQuantity", app: app)
        app.buttons["addPartLink"].click()
        let links = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "partLinkURL-"))
        replace("ftp://example.org/part", field: links.element(boundBy: 0))
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["partSaveError"].waitForExistence(timeout: 3))
        replace("https://example.org/part", field: links.element(boundBy: 0))
        app.buttons["backFromPart"].click()
        XCTAssertTrue(app.sheets.buttons["Stay"].waitForExistence(timeout: 3))
        app.sheets.buttons["Stay"].click()
        XCTAssertEqual(app.textFields["partDescription"].value as? String, "Setting lever spring")
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editPart"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Unknown"].exists)
        app.buttons["editPart"].click()
        enter("0012.3-A/04", identifier: "partManufacturerReference", app: app)
        app.popUpButtons["partCompatibility"].click()
        app.menuItems["Confirmed"].firstMatch.click()
        app.buttons["savePart"].click()
        XCTAssertTrue(app.staticTexts["partSaveError"].waitForExistence(timeout: 3))
        enter("Matches caliber drawing", identifier: "partCompatibilityNote", app: app)
        app.buttons["addPartLink"].click()
        replace("http://example.org/drawing", field: links.element(boundBy: 1))
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editPart"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0012.3-A/04"].exists)
        let openActions = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "openPartLink-"))
        XCTAssertEqual(openActions.count, 2)
        app.buttons["backFromPart"].click()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["addPart"].waitForExistence(timeout: 5))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "part-"))
        rows.firstMatch.click()
        XCTAssertTrue(app.buttons["editPart"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["https://example.org/part"].exists)
        XCTAssertTrue(app.staticTexts["http://example.org/drawing"].exists)
        XCTAssertEqual(openActions.count, 2)
        app.buttons["backFromPart"].click()
        app.buttons["changeJobStage"].click()
        app.popUpButtons["jobStage"].click()
        app.menuItems["Completed"].firstMatch.click()
        enter("Inspection finished", identifier: "jobOutcome", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["jobActionSaveError"].waitForExistence(timeout: 3))
        enter("Owner will source this part", identifier: "jobUnfinishedPartsReason", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["reopenJob"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["addPart"].isEnabled)
        rows.firstMatch.click()
        XCTAssertTrue(app.buttons["editPart"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editPart"].isEnabled)
        XCTAssertTrue(app.staticTexts["Needed"].exists)
        XCTAssertEqual(openActions.count, 2)
    }

    @MainActor
    private func enter(_ text: String, identifier: String, app: XCUIApplication) {
        replace(text, field: app.textFields[identifier])
    }

    @MainActor
    private func replace(_ text: String, field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }
}
