import SwiftUI
import SwiftData

@main
struct PricingStudioApp: App {
    let container: ModelContainer

    init() {
        // Try CloudKit-backed container first; fall back to local-only if
        // the iCloud container isn't provisioned yet.
        if let cloudContainer = try? ModelContainer(
            for: Operator.self, Patron.self, Authority.self, Contact.self, Campaign.self,
            configurations: ModelConfiguration(cloudKitDatabase: .automatic)
        ) {
            container = cloudContainer
        } else {
            container = try! ModelContainer(
                for: Operator.self, Patron.self, Authority.self, Contact.self, Campaign.self
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
