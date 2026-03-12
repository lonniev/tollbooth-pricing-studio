import SwiftUI
import SwiftData

@main
struct PricingStudioApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: Operator.self)
    }
}
