import SwiftUI

/// Shown when the selected entity has no nsec stored in Keychain.
struct NoNsecView: View {
    let entityName: String

    var body: some View {
        ContentUnavailableView {
            Label("No Secret Key", systemImage: "key.slash")
        } description: {
            Text("**\(entityName)** has no nsec stored in Keychain. Edit this entity and add an nsec to enable messaging.")
        }
    }
}
