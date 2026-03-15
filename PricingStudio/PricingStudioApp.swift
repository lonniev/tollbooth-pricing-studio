import SwiftUI
import SwiftData

@main
struct PricingStudioApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // CloudKit sync requires all attributes optional/defaulted and no
        // unique constraints. Until models are migrated, use local-only.
        // TODO: Migrate models for CloudKit compatibility, then switch to:
        //   ModelConfiguration(cloudKitDatabase: .automatic)
        .modelContainer(for: [Operator.self, Patron.self, Authority.self, Contact.self, Campaign.self])
    }
}
