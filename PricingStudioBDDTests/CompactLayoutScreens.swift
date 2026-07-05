import XCTest

/// Not a pass/fail test — a screenshot harness for verifying the iPhone
/// (compact) layouts. Drives the actor-tap → canvas → back → re-tap flow and
/// opens the Traffic Log sheet, attaching a screenshot at each step. Run on an
/// iPhone simulator and pull the images out of the .xcresult:
///
///   xcodebuild test -only-testing:PricingStudioBDDTests/CompactLayoutScreens \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
@MainActor
final class CompactLayoutScreens: XCTestCase {

    func testCaptureCompactScreens() throws {
        let app = XCUIApplication()
        app.launch()

        // The app requests notification authorization on launch; dismiss the
        // system alert so it doesn't cover the sidebar.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }

        // 1. Compact root: the sidebar list (list-first navigation).
        attach(app, "01-sidebar")

        // 2. Tap the always-present Prime Authority row — on compact this must
        //    now PUSH into the actor's detail canvas (the bug: it did nothing).
        let prime = app.staticTexts["DPYC Prime Authority"]
        XCTAssertTrue(prime.waitForExistence(timeout: 10), "Prime Authority row should exist")
        prime.tap()
        sleep(2)
        attach(app, "02-authority-canvas")

        // 3. Back button returns to the sidebar.
        tapBack(app)
        sleep(1)
        attach(app, "03-back-to-sidebar")

        // 4. Re-tapping the SAME row must navigate again (selection is cleared
        //    on back so the unchanged-selection no-op can't strand us).
        let primeAgain = app.staticTexts["DPYC Prime Authority"]
        if primeAgain.waitForExistence(timeout: 5) { primeAgain.tap() }
        sleep(2)
        attach(app, "04-retap-canvas")

        // 5. Back, then open the Traffic Log sheet — verify the compact header
        //    (single Menu, no overflowing segmented pickers).
        tapBack(app)
        sleep(1)
        let tlog = app.buttons["trafficLogToggle"]
        if tlog.waitForExistence(timeout: 5) { tlog.tap() }
        sleep(2)
        attach(app, "05-trafficlog-compact")
    }

    private func tapBack(_ app: XCUIApplication) {
        let named = app.navigationBars.buttons["Pricing Studio"]
        if named.waitForExistence(timeout: 3) {
            named.tap()
            return
        }
        let first = app.navigationBars.buttons.element(boundBy: 0)
        if first.exists { first.tap() }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
