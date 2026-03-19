# Testing — Pricing Studio

## Test Targets

| Target | Type | Runner | Purpose |
|---|---|---|---|
| `PricingStudioTests` | Unit | XCTest | Model/service logic (no UI) |
| `PricingStudioUITests` | UI (XCUITest) | XCTest | Full UI automation against real backend |
| `PricingStudioBDDTests` | UI (BDD) | GherkinRunner | Gherkin `.feature` file-driven UI tests |

## Prerequisites

- iPad connected (USB or WiFi-paired) with at least one operator configured
- Real backend credentials in Keychain (MCP OAuth tokens)
- Real `api_sats` balance for mutating tests (apply action)
- Tests run sequentially (`parallelizable = NO`) to avoid state conflicts

## Running Tests

```bash
make test-ui      # XCUITest suite (6 test classes)
make test-bdd     # BDD feature suite (4 feature files)
```

Or from Xcode: Product > Test (Cmd+U) runs all three test targets.

## Accessibility Identifier Contract

All testable UI elements use `.accessibilityIdentifier()` with these patterns:

| Pattern | View | Element |
|---|---|---|
| `modelListItem_{npub}` | ContentView sidebar | Authority/Operator rows |
| `pipelineStepRow_{index}` | PipelineView | Pipeline step cards |
| `addConstraintButton` | PipelineView | "Add Constraint" button |
| `constraintTypeRow_{type}` | AddConstraintSheet | Constraint type buttons |
| `constraintParamField_{name}` | ConstraintParamEditor | Dynamic form fields |
| `applyButton` | PricingDetailView | "Save to Operator" button |
| `confirmApplyButton` | PricingDetailView | Confirm dialog save button |
| `cancelApplyButton` | PricingDetailView | Confirm dialog cancel button |
| `diffModelALabel` | PricingDiffView | Model A badge |
| `diffModelBLabel` | PricingDiffView | Model B badge |
| `trafficLogRow_{id}` | TrafficLogView | Log entry rows |

**Note**: `confirmApplyButton` and `cancelApplyButton` are inside a `confirmationDialog` which renders as a system action sheet. The `.accessibilityIdentifier` may not propagate — tests fall back to matching by button label text.

## Adding a New BDD Feature

1. Create `PricingStudioBDDTests/Features/my_feature.feature`
2. Add step definitions in `PricingStudioBDDTests/StepDefinitions/MyFeatureSteps.swift`
3. Register steps in `PricingStudioBDDTests/PricingStudioBDDTests.swift`:
   ```swift
   MyFeatureSteps.register(with: runner)
   ```
4. Add a test method:
   ```swift
   func testMyFeature() throws {
       runner.runFeature(named: "my_feature", in: Bundle(for: type(of: self)))
   }
   ```
5. Add the `.feature` file to the BDD target's Resources build phase in Xcode
6. Add the `.swift` file to the BDD target's Sources build phase

## Test Teardown

Mutating tests (ApplyActionTests, PipelineEditorTests) call `TestTeardown.resetBaseline()` in `tearDown` to restore the operator's pricing model via direct HTTP POST to `set_pricing_model`. This bypasses the app's MCP client to avoid coupling teardown to app internals.

Configure via environment variables:
- `TEST_OPERATOR_NPUB` — the operator to reset
- `TEST_MCP_ENDPOINT` — the MCP endpoint base URL

## GherkinRunner

A ~130-line custom Gherkin parser (`GherkinRunner.swift`) that:
- Parses `.feature` files from the test bundle's resources
- Matches `Given`/`When`/`Then`/`And` steps via registered regex patterns
- Passes `XCUIApplication` + regex capture groups to step handlers
- Reports failures with feature file name + line number
- Marked `@MainActor` for Swift 6 concurrency compliance

This replaces Cucumberish (abandoned since 2021, no Swift 6 support).
