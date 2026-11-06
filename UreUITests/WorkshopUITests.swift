import Foundation
import XCTest

nonisolated final class WorkshopUITests: XCTestCase {
    @MainActor
    func testNewJobPicksItsWatchAndJobsGroupsItUntilItIsDone() {
        let app = XCUIApplication()
        app.launchEnvironment["URE_TESTING"] = "1"
        app.launchEnvironment["URE_TEST_LIBRARY_ID"] = UUID().uuidString
        app.launchArguments = ["-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        window.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["newRecord"].waitForExistence(timeout: 5))
        app.buttons["newRecord"].click()
        enter("Workshop watch", identifier: "watchName", app: app)
        window.typeKey(.return, modifierFlags: [])

        // ⌘N in Jobs makes a job without a watch, and the picker comes after its title.
        window.typeKey("1", modifierFlags: .command)
        window.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textFields["jobTitle"].waitForExistence(timeout: 5))
        app.textFields["jobTitle"].typeText("Workshop service")
        window.typeKey(.return, modifierFlags: [])
        let picker = app.textFields["jobWatchPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.typeText("workshop")
        window.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["jobWatch"].waitForExistence(timeout: 5))
        XCTAssertFalse(picker.exists)
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "jobListRow-")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["In progress"].exists)

        // ⌘F puts the cursor in the toolbar's search, which finds within Jobs.
        window.typeKey("f", modifierFlags: .command)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.typeText("Missing job")
        XCTAssertFalse(row.waitForExistence(timeout: 1))
        XCTAssertTrue(app.textFields["jobTitle"].exists)
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(row.waitForExistence(timeout: 3))

        // A Done job moves to Done recently and stays on its watch's page.
        let state = app.descendants(matching: .any)["jobState"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        state.click()
        app.menuItems["Done"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Done recently"].waitForExistence(timeout: 5))
        XCTAssertEqual(state.value as? String, "Done")
        app.buttons["jobWatch"].click()
        let history = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "watchJob-")
        )
        .firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.click()
        XCTAssertEqual(app.textFields["jobTitle"].value as? String, "Workshop service")
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
        XCTAssertFalse(app.staticTexts["No jobs"].exists)
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
        XCTAssertFalse(app.staticTexts["No jobs"].exists)
    }

    @MainActor
    func testKeyboardNavigationAndSettings() {
        let app = XCUIApplication()
        app.launchEnvironment["URE_TESTING"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["No jobs"].waitForExistence(timeout: 5))

        // ⌘1 to ⌘4 select Jobs, Parts, Watches and Calibers, in the sidebar's order.
        let sections = [
            ("2", "Nothing to buy"),
            ("3", "No watches"),
            ("4", "No calibers"),
            ("1", "No jobs"),
        ]

        for (key, emptyTitle) in sections {
            app.typeKey(key, modifierFlags: .command)
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
        XCTAssertTrue(app.staticTexts["No jobs"].waitForExistence(timeout: 5))

        let rightEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        rightEdge.click(
            forDuration: 0.1,
            thenDragTo: rightEdge.withOffset(CGVector(dx: 1000 - window.frame.width, dy: 0)))
        let bottomEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: -1))
        bottomEdge.click(
            forDuration: 0.1,
            thenDragTo: bottomEdge.withOffset(CGVector(dx: 0, dy: 650 - window.frame.height)))

        XCTAssertGreaterThanOrEqual(window.frame.width, 1000)
        XCTAssertLessThanOrEqual(window.frame.width, 1020)
        XCTAssertGreaterThanOrEqual(window.frame.height, 650)
        XCTAssertLessThanOrEqual(window.frame.height, 670)
        XCTAssertTrue(app.staticTexts["No jobs"].exists)
        XCTAssertTrue(app.staticTexts["Select a job"].exists)

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Workshop-minimum-window"
        attachment.lifetime = .keepAlways
        add(attachment)

        window.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["newRecord"].waitForExistence(timeout: 5))
        window.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textFields["watchName"].waitForExistence(timeout: 3))
        window.typeText("Minimum window watch")
        window.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.textFields["watchContact"].isHittable)
        XCTAssertTrue(app.buttons["startWatchJob"].waitForExistence(timeout: 5))

        window.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.buttons["newRecord"].waitForExistence(timeout: 5))
        window.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textFields["caliberName"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["caliberLiftAngle"].isHittable)
        XCTAssertTrue(app.buttons["newRecord"].isHittable)
        app.terminate()
    }
}
