Feature: Patron CRUD
  As a Pricing Studio user, I need to create, view, update, and delete patrons
  using generated Nostr keypairs.

  Scenario: Create patron with generated keys
    Given the app is launched
    When I tap the add menu
    And I tap "Add Patron"
    Then I should see the "Add Patron" sheet
    When I tap "Generate Nostr Keys"
    Then the keys should be generated
    When I enter "BDD Test Patron" as the display name
    And I tap the "Add" button
    Then I should see "BDD Test Patron" in the sidebar

  Scenario: Edit patron display name
    Given an entity named "BDD Test Patron" exists in the sidebar
    When I open the context menu for "BDD Test Patron"
    And I tap "Edit"
    Then I should see the "Edit Patron" sheet
    When I clear and type "BDD Renamed Patron" in the display name field
    And I tap the "Save" button
    Then I should see "BDD Renamed Patron" in the sidebar

  Scenario: Delete patron with confirmation
    Given an entity named "BDD Renamed Patron" exists in the sidebar
    When I swipe to delete "BDD Renamed Patron"
    Then I should see a delete confirmation dialog
    When I confirm the deletion
    Then "BDD Renamed Patron" should no longer appear in the sidebar
