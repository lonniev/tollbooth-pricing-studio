Feature: Authority CRUD
  As a Pricing Studio user, I need to create, view, update, and delete authorities
  using generated Nostr keypairs.

  Scenario: Create authority with generated keys
    Given the app is launched
    When I tap the add menu
    And I tap "Add Authority"
    Then I should see the "Add Authority" sheet
    When I tap "Generate Nostr Keys"
    Then the keys should be generated
    When I enter "BDD Test Authority" as the display name
    And I tap the "Add" button
    Then I should see "BDD Test Authority" in the sidebar

  Scenario: Edit authority display name
    Given an entity named "BDD Test Authority" exists in the sidebar
    When I open the context menu for "BDD Test Authority"
    And I tap "Edit"
    Then I should see the "Edit Authority" sheet
    When I clear and type "BDD Renamed Authority" in the display name field
    And I tap the "Save" button
    Then I should see "BDD Renamed Authority" in the sidebar

  Scenario: Delete authority with confirmation
    Given an entity named "BDD Renamed Authority" exists in the sidebar
    When I swipe to delete "BDD Renamed Authority"
    Then I should see a delete confirmation dialog
    When I confirm the deletion
    Then "BDD Renamed Authority" should no longer appear in the sidebar
