import XCTest

@MainActor
enum AppLaunchSteps {
    static func register(with runner: GherkinRunner) {
        runner.given("the app is launched") { app, _ in
            XCTAssertTrue(app.exists, "App should be running")
        }

        runner.then("the sidebar should be visible") { app, _ in
            let sidebar = app.navigationBars["Pricing Studio"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "Sidebar should be visible")
        }

        runner.then("I should see the \"(.+)\" section") { app, captures in
            guard let sectionName = captures.first else {
                XCTFail("Missing section name capture")
                return
            }
            let section = app.staticTexts[sectionName]
            XCTAssertTrue(section.waitForExistence(timeout: 10), "\(sectionName) section should exist")
        }
    }
}
