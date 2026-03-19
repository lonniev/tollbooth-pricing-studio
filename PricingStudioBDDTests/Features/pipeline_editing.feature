Feature: Pipeline Editing
  Verify constraint pipeline editing workflow.

  Scenario: Edit mode shows add constraint button
    Given I am viewing an operator's pricing
    When I enter pipeline edit mode
    Then I should see the add constraint button

  Scenario: Add constraint shows type options
    Given I am viewing an operator's pricing
    When I enter pipeline edit mode
    And I tap add constraint
    Then I should see constraint type options

  Scenario: Selecting constraint type shows param editor
    Given I am viewing an operator's pricing
    When I enter pipeline edit mode
    And I tap add constraint
    And I select the first constraint type
    Then I should see parameter fields
