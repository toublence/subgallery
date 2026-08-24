import XCTest

final class ReminderFlowUITests: XCTestCase {
    func testNotificationOpensTheExactPhoto() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]

        addUIInterruptionMonitor(withDescription: "Notification permission") { alert in
            let allow = alert.buttons["허용"]
            if allow.exists { allow.tap(); return true }
            let englishAllow = alert.buttons["Allow"]
            if englishAllow.exists { englishAllow.tap(); return true }
            return false
        }

        app.launch()
        let allAlbum = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "전체")).firstMatch
        XCTAssertTrue(allAlbum.waitForExistence(timeout: 8))
        allAlbum.tap()

        let fixture = app.descendants(matching: .any)["__SubGalleryUITest.jpg"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 8))
        fixture.tap()

        let actions = app.buttons["사진 동작"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        app.buttons["다시 알려주기"].tap()

        let testReminder = app.buttons["5초 후 (테스트)"]
        XCTAssertTrue(testReminder.waitForExistence(timeout: 5))
        testReminder.tap()
        app.tap()

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notification = springboard.staticTexts["저장해둔 사진을 확인할 시간이에요."]
        XCTAssertTrue(notification.waitForExistence(timeout: 15))
        notification.tap()

        XCTAssertTrue(app.buttons["사진 동작"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["완료 대기"].exists)

        app.terminate()
        app.launchArguments = ["-ui-testing", "-ui-test-cleanup-only"]
        app.launch()
        XCTAssertTrue(app.navigationBars["보관함"].waitForExistence(timeout: 8))
        app.terminate()
    }
}
