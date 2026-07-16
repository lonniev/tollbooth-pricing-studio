import SwiftUI
import PricingStudioCore

/// A Form section carrying the per-identity Nostr-notification mute toggle,
/// shared by the Operator, Patron, and Authority edit sheets so the control
/// and its copy live in exactly one place.
///
/// The toggle is a device-local preference, not part of the entity record, so
/// it persists immediately on change (independent of the sheet's Save button)
/// — a Cancel never silently reverts it. `onChanged` lets the host sheet also
/// enable its Save button, so the change is visibly acknowledged.
struct NotificationToggleSection: View {
    let npub: String
    /// Called only on a genuine user toggle (not the initial load), so the
    /// host can mark its form dirty.
    var onChanged: (() -> Void)? = nil

    @State private var enabled = true

    var body: some View {
        Section {
            // A custom binding, not `$enabled`: the setter fires ONLY when the
            // user flips the switch. Binding to $enabled would also run the
            // side effects when `.task` loads the stored value, spuriously
            // re-saving the preference and dirtying the form on open.
            Toggle(isOn: Binding(
                get: { enabled },
                set: { newValue in
                    guard newValue != enabled else { return }
                    enabled = newValue
                    NostrNotificationPreferences.setEnabled(newValue, npub: npub)
                    onChanged?()
                }
            )) {
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
    }
}
