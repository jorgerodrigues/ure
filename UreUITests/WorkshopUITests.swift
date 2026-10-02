import Foundation
import XCTest

nonisolated final class WorkshopUITests: XCTestCase {
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
            XCTAssertTrue(app.staticTexts["Select a record"].waitForExistence(timeout: 5))

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
        XCTAssertTrue(app.staticTexts["Select a record"].exists)

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Workshop-minimum-window"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
