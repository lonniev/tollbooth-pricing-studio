import XCTest

/// Not a pass/fail test — a screenshot harness for the iPhone (compact) build.
/// `testCaptureCompactScreens` verifies the actor-tap → canvas → back → re-tap
/// navigation and the Traffic Log sheet. `testCaptureAppStoreScreens` walks the
/// marketing surfaces (Milo greeting, sidebar, connection graph, actor canvas)
/// for the App Store listing. Run on a 6.9" iPhone simulator and pull the
/// images out of the .xcresult:
///
///   xcodebuild test \
///     -only-testing:PricingStudioBDDTests/CompactLayoutScreens \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
///     -resultBundlePath X.xcresult TARGETED_DEVICE_FAMILY="1,2"
///   xcrun xcresulttool export attachments --path X.xcresult --output-path OUT
@MainActor
final class CompactLayoutScreens: XCTestCase {

    func testCaptureCompactScreens() throws {
        let app = XCUIApplication()
        app.launch()
        dismissLaunchChrome(app)

        // 1. Compact root: the sidebar list (list-first navigation).
        attach(app, "01-sidebar")

        // 2. Tap the always-present Prime Authority row — on compact this must
        //    PUSH into the actor's detail canvas (the bug: it did nothing).
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

    /// Marketing surfaces for the App Store listing, in listing order.
    func testCaptureAppStoreScreens() throws {
        let app = XCUIApplication()
        app.launch()

        // The Allow alert is dismissed first, but the Milo greeting cover is
        // itself the first marketing shot — capture it BEFORE dismissing.
        dismissAllowAlert(app)
        attach(app, "01-milo-greeting")

        // Tap-to-begin dismisses the greeting.
        dismissSplash(app)

        // Cold boot fires system suggestion banners ("Ready for Apple
        // Intelligence") that auto-dismiss after a few seconds. App Store
        // rejects screenshots showing them — wait them out before capturing.
        sleep(12)
        attach(app, "02-network-sidebar")

        // The always-available Network Topology row opens the connection graph
        // (the hero shot — nodes + edges across the DPYC federation).
        let network = app.buttons["Network Topology"]
        if network.waitForExistence(timeout: 5) {
            network.tap()
        } else {
            app.staticTexts["Network Topology"].tap()
        }
        sleep(3)
        attach(app, "03-connection-graph")
    }

    // MARK: - Helpers

    /// Dismiss the notification-permission alert, then the Milo greeting cover.
    private func dismissLaunchChrome(_ app: XCUIApplication) {
        dismissAllowAlert(app)
        dismissSplash(app)
    }

    private func dismissAllowAlert(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }

    /// The Milo greeting is a full-screen cover dismissed by any tap.
    private func dismissSplash(_ app: XCUIApplication) {
        let begin = app.staticTexts["Tap to begin"]
        if begin.waitForExistence(timeout: 5) {
            begin.tap()
        } else {
            app.tap()
        }
        sleep(1)
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
