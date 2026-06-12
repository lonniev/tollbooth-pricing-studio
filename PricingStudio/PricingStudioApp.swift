import SwiftUI
import SwiftData
import UserNotifications
import BackgroundTasks

/// Shared SwiftData container — used by the app scene AND by the background
/// DM-refresh task, which has no view to inherit a container from.
enum AppModelContainer {
    static let shared: ModelContainer = {
        let schema = Schema([Operator.self, Patron.self, Authority.self, Contact.self, Campaign.self])
        let config = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        if let container = try? ModelContainer(for: schema, configurations: [config]) {
            return container
        }
        // Fallback to local-only if the CloudKit container isn't provisioned.
        let localConfig = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        return try! ModelContainer(for: schema, configurations: [localConfig])
    }()
}

@main
struct PricingStudioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    Authority.ensurePrimeExists(in: AppModelContainer.shared.mainContext)
                    LoadingQuoteView.prefetch()
                }
        }
        .modelContainer(AppModelContainer.shared)
    }
}

/// AppDelegate: foreground notification display + background DM refresh.
class AppDelegate: NSObject, UIApplicationDelegate {
    /// Must match an identifier in Info.plist `BGTaskSchedulerPermittedIdentifiers`.
    static let dmRefreshTaskID = "com.tollbooth.dpyc.PricingStudio.dmrefresh"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared

        // Register the background DM-refresh handler (must happen before launch
        // completes) and queue the first opportunity.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.dmRefreshTaskID, using: nil
        ) { [weak self] task in
            self?.handleDMRefresh(task as! BGAppRefreshTask)
        }
        scheduleDMRefresh()
        return true
    }

    /// Re-arm the background refresh each time we leave the foreground.
    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleDMRefresh()
    }

    /// Ask iOS to wake us (no sooner than ~15 min from now) to drain DMs. iOS
    /// decides the actual cadence from usage, battery, and the user's
    /// Background App Refresh setting — this is opportunistic, not real-time.
    private func scheduleDMRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.dmRefreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// One opportunistic background drain: fetch new DMs, post notifications,
    /// then complete. Always reschedules first so the chain continues.
    ///
    /// iOS grants a BGAppRefreshTask only ~30s and KILLS the app (watchdog) if
    /// `setTaskCompleted` is not called in time. The drain itself can race past
    /// that budget (and `work.cancel()` cannot interrupt the detached relay
    /// fetch), so we MUST guarantee a completion signal from whichever fires
    /// first — the drain finishing or iOS expiring us. The latch makes that
    /// call exactly-once; calling `setTaskCompleted` twice is itself a crash.
    private func handleDMRefresh(_ task: BGAppRefreshTask) {
        scheduleDMRefresh()

        let latch = CompletionLatch()
        let work = Task {
            await DMPollingService.shared.runBackgroundDrain()
            if latch.tryComplete() {
                task.setTaskCompleted(success: !Task.isCancelled)
            }
        }
        task.expirationHandler = {
            work.cancel()
            if latch.tryComplete() {
                task.setTaskCompleted(success: false)
            }
        }
    }
}

/// Thread-safe one-shot flag: the BGTask completion and its expiration handler
/// run on different threads and either may win the race. `tryComplete()` lets
/// exactly one of them call `setTaskCompleted`.
private final class CompletionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func tryComplete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Separate class to handle foreground notification display without Sendable issues.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()

    /// Show notification banners even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
