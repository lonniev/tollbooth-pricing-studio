import SwiftUI
import SwiftData

@main
struct PricingStudioApp: App {
    let modelContainer: ModelContainer

    init() {
        let schema = Schema([Operator.self, Patron.self, Authority.self, Contact.self, Campaign.self])
        let config = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Fallback to local-only if CloudKit container not provisioned
            let localConfig = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            modelContainer = try! ModelContainer(for: schema, configurations: [localConfig])
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
