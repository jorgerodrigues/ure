import Foundation
import XCTest

nonisolated final class WorkshopUITests: XCTestCase {
    @MainActor
    func testWorkshopFiltersRetainJobAndKeyboardSaveThenClosureKeepsHistory() {
        let app = XCUIApplication()
        app.launchEnvironment["URE_TESTING"] = "1"
        app.launchEnvironment["URE_TEST_LIBRARY_ID"] = UUID().uuidString
        app.launchArguments = ["-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }
        app.windows.firstMatch.typeKey("2", modifierFlags: [.command, .option])
        XCTAssertTrue(app.buttons["addWatch"].waitForExistence(timeout: 5))
        app.buttons["addWatch"].click()
        enter("Workshop watch", identifier: "watchName", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["startWatchJob"].waitForExistence(timeout: 5))
        app.buttons["startWatchJob"].click()
        enter("Workshop service", identifier: "jobTitle", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editJob"].waitForExistence(timeout: 5))
        app.windows.firstMatch.typeKey("1", modifierFlags: [.command, .option])
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "workshopJob-")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        XCTAssertTrue(app.staticTexts["Workshop service"].exists)
        app.popUpButtons["workshopStageFilter"].click()
        app.menuItems["Waiting"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["No matching jobs"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["editJob"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["workshopSelectionMessage"].exists)
        app.buttons["Clear Filters"].firstMatch.click()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        let search = app.searchFields.firstMatch
        search.click()
        search.typeText("Missing job")
        XCTAssertTrue(app.staticTexts["No matching jobs"].waitForExistence(timeout: 3))
        app.buttons["Clear Filters"].firstMatch.click()
        app.buttons["editJob"].click()
        enter("Corrected workshop service", identifier: "jobTitle", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["editJob"].waitForExistence(timeout: 5))
        app.buttons["changeJobStage"].click()
        app.popUpButtons["jobStage"].click()
        app.menuItems["Completed"].firstMatch.click()
        enter("Reviewed", identifier: "jobOutcome", app: app)
        app.windows.firstMatch.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["No open jobs"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reopenJob"].exists)
        app.buttons["backToWatch"].click()
        let history = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "watchJob-")
        )
        .firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.click()
        XCTAssertTrue(app.buttons["reopenJob"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func enter(_ value: String, identifier: String, app: XCUIApplication) {
        let field = app.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
    }

    @MainActor
    func testRecoveryKeepsDamagedLibraryWhenRetried() {
        let app = XCUIApplication()
        app.launchEnvironment["URE_TESTING"] = "1"
        app.launchEnvironment["URE_TEST_CORRUPT_POINTER"] = "1"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Library needs recovery"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["No open jobs"].exists)
        let reason = app.staticTexts["libraryRecoveryReason"]
        XCTAssertTrue(reason.exists)
        let initialReason = reason.value as? String ?? reason.label
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Library-recovery"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["retryLibrary"].click()
        XCTAssertTrue(app.staticTexts["Library needs recovery"].waitForExistence(timeout: 5))
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        XCTAssertEqual(reason.value as? String ?? reason.label, initialReason)
        XCTAssertFalse(app.staticTexts["No open jobs"].exists)
    }

    @MainActor
    func testKeyboardNavigationAndSettings() {
        let app = XCUIApplication()
        app.launchEnvironment["URE_TESTING"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["No open jobs"].waitForExistence(timeout: 5))

        let sections = [
            ("2", "No watches"),
            ("3", "No calibers"),
            ("4", "No required parts"),
            ("5", "No archived records"),
            ("1", "No open jobs"),
        ]

        for (key, emptyTitle) in sections {
            app.typeKey(key, modifierFlags: [.command, .option])
            XCTAssertTrue(app.staticTexts[emptyTitle].waitForExistence(timeout: 3))
        }

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Application"].waitForExistence(timeout: 3))
        app.terminate()
    }

    @MainActor
    func testWindowLaunchesInBothAppearances() {
        for appearance in ["Light", "Dark"] {
            let app = XCUIApplication()
            app.launchEnvironment["URE_TESTING"] = "1"
            app.launchArguments = ["-AppleInterfaceStyle", appearance]
            app.launch()

            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(window.frame.width, 1000)
            XCTAssertGreaterThanOrEqual(window.frame.height, 650)
            XCTAssertTrue(app.staticTexts["Select a job"].waitForExistence(timeout: 5))

            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "Workshop-\(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    @MainActor
    func testMinimumWindowKeepsNavigationAndDetailVisible() {
        let app = XCUIApplication()
        app.launchEnvironment["URE_TESTING"] = "1"
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No open jobs"].waitForExistence(timeout: 5))

        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        let destination = corner.withOffset(
            CGVector(dx: 1000 - window.frame.width, dy: 650 - window.frame.height)
        )
        corner.press(forDuration: 0.1, thenDragTo: destination)

        XCTAssertGreaterThanOrEqual(window.frame.width, 1000)
        XCTAssertLessThanOrEqual(window.frame.width, 1020)
        XCTAssertGreaterThanOrEqual(window.frame.height, 650)
        XCTAssertTrue(app.staticTexts["No open jobs"].exists)
        XCTAssertTrue(app.staticTexts["Select a job"].exists)

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Workshop-minimum-window"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
