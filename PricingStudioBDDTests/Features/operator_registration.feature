Feature: Operator Registration
  Verify that operators appear in the sidebar and can be selected.

  Scenario: App launches with sidebar visible
    Given the app is launched
    Then the sidebar should be visible
    And I should see the "Authorities" section
    And I should see the "Operators" section

  Scenario: Operator rows have accessibility identifiers
    Given at least one operator exists
    Then the operator row should have an accessibility identifier

  Scenario: Selecting an operator loads pricing detail
    Given at least one operator exists
    When I tap the first operator row
    Then the pricing detail should load
