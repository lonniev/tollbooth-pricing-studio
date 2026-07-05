import SwiftUI

/// A Form section carrying the per-identity Nostr-notification mute toggle,
/// shared by the Operator, Patron, and Authority edit sheets so the control
/// and its copy live in exactly one place.
///
/// The toggle is a device-local preference, not part of the entity record, so
/// it persists immediately on change (independent of the sheet's Save button).
struct NotificationToggleSection: View {
    let npub: String
    @State private var enabled = true

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                Label("Nostr Notifications", systemImage: enabled ? "bell" : "bell.slash")
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("When off, new Nostr DMs and approval requests for this identity won't show banners or add to the app badge. Background sync continues, so messages still appear inside the app.")
        }
        .task {
            enabled = NostrNotificationPreferences.isEnabled(npub: npub)
        }
        .onChange(of: enabled) { _, newValue in
            NostrNotificationPreferences.setEnabled(newValue, npub: npub)
        }
    }
}
