Feature: Apply Action
  Verify save-to-operator flow with confirmation dialog.

  Scenario: Apply button triggers confirmation
    Given I have made pricing edits
    When I tap the apply button
    Then I should see a confirmation dialog

  Scenario: Cancel returns to edit state
    Given I have made pricing edits
    When I tap the apply button
    And I cancel the confirmation
    Then the apply button should still be visible
