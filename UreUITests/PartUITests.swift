import XCTest

nonisolated final class PartUITests: XCTestCase {
    @MainActor
    func testPartsAreTypedOnOneLineAndTheStateMovesOnWithUndo() {
        let app = isolatedApp()
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        // New Part in Parts makes a spare in the drawer, with the cursor in its name.
        XCTAssertTrue(app.outlines["Workshop sections"].waitForExistence(timeout: 5))
        window.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.buttons["newRecord"].waitForExistence(timeout: 5))
        app.buttons["newRecord"].click()
        XCTAssertTrue(app.textFields["partTitle"].waitForExistence(timeout: 5))
        window.typeText("Crystal 30.0 mm")
        window.typeKey(.return, modifierFlags: [])
        createWatch(app)
        app.buttons["startWatchJob"].click()
        XCTAssertTrue(app.textFields["jobTitle"].waitForExistence(timeout: 5))
        window.typeText("Full service")
        window.typeKey(.return, modifierFlags: [])

        // Each part takes one line, and the spare in hand is one arrow away.
        let add = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "addPart-")
        )
        .firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()
        window.typeText("Mainspring")
        window.typeKey(.return, modifierFlags: [])
        window.typeText("crystal")
        let spare = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "useSpare-")
        ).firstMatch
        XCTAssertTrue(spare.waitForExistence(timeout: 3))
        window.typeKey(.downArrow, modifierFlags: [])
        window.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(names(app), ["Mainspring", "Crystal 30.0 mm"])

        // A click on the state moves the part on, and ⌘Z puts it back.
        let state = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "partState-")
        ).element(boundBy: 0)
        XCTAssertEqual(state.value as? String, "Needed")
        state.click()
        XCTAssertEqual(state.value as? String, "Ordered")
        window.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(state.value as? String, "Needed")
    }

    // The names on the job's part lines, from top to bottom.
    @MainActor
    private func names(_ app: XCUIApplication) -> [String] {
        app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "partName-"))
            .allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }
            .compactMap { $0.value as? String }
    }

    @MainActor
    private func isolatedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["URE_TESTING"] = "1"
        app.launchEnvironment["URE_TEST_LIBRARY_ID"] = UUID().uuidString
        app.launchArguments = ["-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        return app
    }

    @MainActor
    private func createWatch(_ app: XCUIApplication) {
        app.windows.firstMatch.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["newRecord"].waitForExistence(timeout: 5))
        app.buttons["newRecord"].click()
        let name = app.textFields["watchName"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText("Parts watch")
        app.windows.firstMatch.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["startWatchJob"].waitForExistence(timeout: 5))
    }
}
