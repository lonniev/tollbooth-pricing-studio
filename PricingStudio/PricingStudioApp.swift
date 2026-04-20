import SwiftUI
import SwiftData
import UserNotifications

@main
struct PricingStudioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
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
                .onAppear {
                    Authority.ensurePrimeExists(in: modelContainer.mainContext)
                    LoadingQuoteView.prefetch()
                }
        }
        .modelContainer(modelContainer)
    }
}

/// AppDelegate to handle foreground notification display.
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let delegate = NotificationDelegate.shared
        UNUserNotificationCenter.current().delegate = delegate
        return true
    }
}

/// Separate class to handle foreground notification display without Sendable issues.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()

    /// Show notification banners even when app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
