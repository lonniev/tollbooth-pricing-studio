Feature: Nostr Messaging
  As a Pricing Studio user, I need to send and receive encrypted
  DMs with entities using Nostr relay infrastructure.

  Scenario: Alice sends a DM and Bob receives it
    Given the app is launched
    And a patron named "Alice BDD" with nsec exists in the sidebar
    And a patron named "Bob BDD" with nsec exists in the sidebar
    When I tap "Alice BDD" in the sidebar
    And I tap the "Messages" tab
    And I compose a DM to Bob's npub with "Hello from Alice"
    Then the sent message "Hello from Alice" should appear in Alice's conversation
    When I wait for Bob's DM polling to detect the message
    Then a message indicator should appear for "Bob BDD" in the sidebar

  Scenario: Navigate to Messages tab for a patron
    Given the app is launched
    And a patron named "Alice BDD" with nsec exists in the sidebar
    When I tap "Alice BDD" in the sidebar
    And I tap the "Messages" tab
    Then I should see the messaging interface
