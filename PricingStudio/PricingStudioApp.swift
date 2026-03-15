import SwiftUI
import SwiftData

@main
struct PricingStudioApp: App {
    let container: ModelContainer

    init() {
        let config = ModelConfiguration(cloudKitDatabase: .automatic)
        container = try! ModelContainer(
            for: Operator.self, Patron.self, Authority.self, Contact.self, Campaign.self,
            configurations: config
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
