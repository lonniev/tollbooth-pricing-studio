import XCTest

/// Lightweight Gherkin parser and step runner for XCUITest-based BDD.
///
/// Parses `.feature` files and dispatches steps to registered closures.
/// Reports failures with feature file name and line number.
@MainActor
final class GherkinRunner {
    typealias StepHandler = (XCUIApplication, [String]) throws -> Void

    private var givenSteps: [(pattern: NSRegularExpression, handler: StepHandler)] = []
    private var whenSteps: [(pattern: NSRegularExpression, handler: StepHandler)] = []
    private var thenSteps: [(pattern: NSRegularExpression, handler: StepHandler)] = []

    private let app: XCUIApplication

    init(app: XCUIApplication) {
        self.app = app
    }

    // MARK: - Step Registration

    func given(_ pattern: String, handler: @escaping StepHandler) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("Invalid regex pattern: \(pattern)")
            return
        }
        givenSteps.append((regex, handler))
    }

    func when(_ pattern: String, handler: @escaping StepHandler) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("Invalid regex pattern: \(pattern)")
            return
        }
        whenSteps.append((regex, handler))
    }

    func then(_ pattern: String, handler: @escaping StepHandler) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("Invalid regex pattern: \(pattern)")
            return
        }
        thenSteps.append((regex, handler))
    }

    // MARK: - Feature Execution

    /// Runs all scenarios in a `.feature` file bundled as a resource.
    func runFeature(named name: String, in bundle: Bundle, file: StaticString = #file, line: UInt = #line) {
        guard let url = bundle.url(forResource: name, withExtension: "feature") else {
            XCTFail("Feature file not found: \(name).feature", file: file, line: line)
            return
        }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Could not read feature file: \(name).feature", file: file, line: line)
            return
        }

        let lines = content.components(separatedBy: .newlines)
        var scenarioName = ""
        var featureLine: UInt = 0

        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let lineNumber = UInt(index + 1)

            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("Feature:") {
                continue
            }

            if trimmed.hasPrefix("Scenario:") {
                scenarioName = String(trimmed.dropFirst("Scenario:".count)).trimmingCharacters(in: .whitespaces)
                featureLine = lineNumber
                continue
            }

            if trimmed.hasPrefix("Given ") {
                let stepText = String(trimmed.dropFirst("Given ".count))
                executeStep(stepText, in: givenSteps, keyword: "Given", feature: name, lineNumber: lineNumber, scenario: scenarioName)
            } else if trimmed.hasPrefix("When ") {
                let stepText = String(trimmed.dropFirst("When ".count))
                executeStep(stepText, in: whenSteps, keyword: "When", feature: name, lineNumber: lineNumber, scenario: scenarioName)
            } else if trimmed.hasPrefix("Then ") {
                let stepText = String(trimmed.dropFirst("Then ".count))
                executeStep(stepText, in: thenSteps, keyword: "Then", feature: name, lineNumber: lineNumber, scenario: scenarioName)
            } else if trimmed.hasPrefix("And ") {
                // "And" reuses the last keyword's step registry — default to Given
                let stepText = String(trimmed.dropFirst("And ".count))
                let matched = executeStep(stepText, in: givenSteps, keyword: "And(Given)", feature: name, lineNumber: lineNumber, scenario: scenarioName)
                    || executeStep(stepText, in: whenSteps, keyword: "And(When)", feature: name, lineNumber: lineNumber, scenario: scenarioName)
                    || executeStep(stepText, in: thenSteps, keyword: "And(Then)", feature: name, lineNumber: lineNumber, scenario: scenarioName)
                if !matched {
                    XCTFail("[\(name).feature:\(lineNumber)] No step definition matches: And \(stepText) (scenario: \(scenarioName))")
                }
            }
        }
    }

    // MARK: - Step Dispatch

    @discardableResult
    private func executeStep(
        _ text: String,
        in registry: [(pattern: NSRegularExpression, handler: StepHandler)],
        keyword: String,
        feature: String,
        lineNumber: UInt,
        scenario: String
    ) -> Bool {
        let range = NSRange(text.startIndex..., in: text)

        for (pattern, handler) in registry {
            if let match = pattern.firstMatch(in: text, range: range) {
                var captures: [String] = []
                for i in 1..<match.numberOfRanges {
                    if let captureRange = Range(match.range(at: i), in: text) {
                        captures.append(String(text[captureRange]))
                    }
                }

                do {
                    try handler(app, captures)
                } catch {
                    XCTFail("[\(feature).feature:\(lineNumber)] \(keyword) \(text) — \(error) (scenario: \(scenario))")
                }
                return true
            }
        }

        // No match found in this registry
        return false
    }
}
