Feature: Traffic Log
  Verify traffic log displays entries and redacts secrets.

  Scenario: Traffic log shows entries after navigation
    Given the traffic log is visible
    When I navigate to an operator
    Then traffic log entries should appear

  Scenario: Traffic log does not expose nsec keys
    Given the traffic log is visible
    When I navigate to an operator
    Then no nsec keys should be visible
