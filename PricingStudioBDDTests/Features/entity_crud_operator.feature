Feature: Operator CRUD
  As a Pricing Studio user, I need to create, view, update, and delete operators
  using generated Nostr keypairs.

  Scenario: Create operator with generated keys
    Given the app is launched
    When I tap the add menu
    And I tap "Add Operator"
    Then I should see the "Add Operator" sheet
    When I tap "Generate Nostr Keys"
    Then the keys should be generated
    When I enter "BDD Test Operator" as the display name
    And I tap the "Add" button
    Then I should see "BDD Test Operator" in the sidebar

  Scenario: Edit operator display name
    Given an entity named "BDD Test Operator" exists in the sidebar
    When I open the context menu for "BDD Test Operator"
    And I tap "Edit"
    Then I should see the "Edit Operator" sheet
    When I clear and type "BDD Renamed Operator" in the display name field
    And I tap the "Save" button
    Then I should see "BDD Renamed Operator" in the sidebar

  Scenario: Delete operator with confirmation
    Given an entity named "BDD Renamed Operator" exists in the sidebar
    When I swipe to delete "BDD Renamed Operator"
    Then I should see a delete confirmation dialog
    When I confirm the deletion
    Then "BDD Renamed Operator" should no longer appear in the sidebar
