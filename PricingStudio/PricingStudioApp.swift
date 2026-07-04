import CloudKit
import DPYCAuthKit
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
                // App-wide: any text is selectable and ⌘C-copyable, no per-view
                // Copy controls needed. textSelection propagates through the
                // environment, including into sheets and navigation destinations.
                .textSelection(.enabled)
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

        // Wrist Approval: Approve/Reject actions on proof-challenge banners.
        // iOS mirrors these to the watch as a popup with the same buttons.
        UNUserNotificationCenter.current().setNotificationCategories([
            ProofApprovalService.makeCategory(),
        ])

        // Register the background DM-refresh handler (must happen before launch
        // completes) and queue the first opportunity.
        //
        // Register on the MAIN queue — this is load-bearing. BGTaskScheduler's
        // launchHandler is a non-Sendable ObjC block (no NS_SWIFT_SENDABLE), so
        // a closure written here, inside the @MainActor didFinishLaunching, is
        // inferred @MainActor-isolated — as are handleDMRefresh and the
        // @MainActor DMPollingService it drives. With `using: nil` the system
        // runs that closure on a BACKGROUND queue, and the Swift runtime's
        // isolation check traps on closure entry (dispatch_assert_queue → brk 1)
        // before the body even runs — so no amount of hopping inside the body
        // helps. Running the handler (and its same-queue expirationHandler) on
        // the main queue satisfies the main-actor executor; BGTask is also
        // non-Sendable, so keeping it main-confined avoids a Sendable boundary.
        // The heavy work is still offloaded inside runBackgroundDrain.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.dmRefreshTaskID, using: .main
        ) { [weak self] task in
            self?.handleDMRefresh(task as! BGAppRefreshTask)
        }
        scheduleDMRefresh()

        // InboxSignal wake-up relay: CloudKit subscription pushes (written by
        // the user's other device when a gift wrap lands) arrive as remote
        // notifications. CloudKit manages the APNs token itself; we only need
        // registration to have happened.
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        TrafficLogger.shared.log(.inbound, label: "InboxSignal", detail: "APNs registered (\(deviceToken.prefix(4).map { String(format: "%02x", $0) }.joined())…)")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "APNs registration failed: \(error.localizedDescription)")
    }

    /// InboxSignal push receipt: another of the user's devices saw a gift wrap
    /// land and wrote the CloudKit marker. A query subscription arrives as an
    /// alert push with record details (record the CK banner as this event's
    /// announcement); the database-subscription fallback arrives silent and
    /// detail-free (the drain's own local notification announces the DM).
    /// Either way, drain the relays so the DM is local before the user looks.
    /// Same ~30s budget and exactly-once completion rules as the BGAppRefresh
    /// path.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo),
              let subscriptionID = note.subscriptionID,
              InboxSignalService.knownSubscriptionIDs.contains(subscriptionID) else {
            TrafficLogger.shared.log(.error, label: "InboxSignal", detail: "push ignored (not an InboxSignal subscription)")
            completionHandler(.noData)
            return
        }

        TrafficLogger.shared.log(.inbound, label: "InboxSignal", detail: "push received (\(subscriptionID)); draining")

        if let queryNote = note as? CKQueryNotification,
           let eventId = queryNote.recordID?.recordName,
           let npub = queryNote.recordFields?["npub"] as? String {
            DMPollingService.shared.recordRemoteAnnouncement(npub: npub, eventId: eventId)
        }

        let latch = CompletionLatch()
        let work = Task {
            await DMPollingService.shared.runBackgroundDrain()
            if latch.tryComplete() {
                completionHandler(.newData)
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(25))
            work.cancel()
            if latch.tryComplete() {
                completionHandler(.newData)
            }
        }
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

    /// Wrist Approval actions. A watch tap forwards here with the app in the
    /// background and the iPhone typically still locked — everything needed
    /// to reply travels in the notification's userInfo, and the nsec is
    /// readable while locked (AfterFirstUnlockThisDeviceOnly).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard let request = ProofApprovalService.ApprovalRequest(
            userInfo: response.notification.request.content.userInfo
        ) else {
            completionHandler()
            return
        }

        let action = response.actionIdentifier
        // The ObjC completion block isn't @Sendable; it's called exactly once
        // (latch-guarded on the approve path), so the box is sound.
        let completion = SendableCompletion(run: completionHandler)
        Task { @MainActor in
            switch action {
            case ProofApprovalService.approveActionId:
                Self.sendApproval(request, completion: completion)
            case ProofApprovalService.rejectActionId:
                // No reject wire message exists — the operator's drain simply
                // finds no reply. Log the decision and move on.
                TrafficLogger.shared.log(.outbound, label: "Wrist Reject", detail: "challenge \(request.eventId.prefix(8)) rejected; no reply sent", npub: request.signerNpub)
                completion.run()
            case UNNotificationDismissActionIdentifier:
                TrafficLogger.shared.log(.outbound, label: "Wrist Approval", detail: "challenge \(request.eventId.prefix(8)) dismissed", npub: request.signerNpub)
                completion.run()
            default:
                // Plain tap — no custom routing this round.
                completion.run()
            }
        }
    }

    /// Sign and publish the precomputed approval reply to the pinned
    /// rendezvous relay. Same exactly-once completion discipline as the
    /// BGTask/push paths: whichever of {send finished, 25s watchdog,
    /// background-time expiry} fires first ends the background task and
    /// calls the notification completion.
    @MainActor
    private static func sendApproval(
        _ request: ProofApprovalService.ApprovalRequest,
        completion: SendableCompletion
    ) {
        TrafficLogger.shared.log(.outbound, label: "Wrist Approve", detail: "challenge \(request.eventId.prefix(8)) approved; replying as \(request.signerNpub.prefix(12))…", npub: request.signerNpub)

        let latch = CompletionLatch()
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        let finish: @MainActor () -> Void = {
            guard latch.tryComplete() else { return }
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
            }
            completion.run()
        }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "wrist-approve") {
            finish()
        }

        let work = Task { @MainActor in
            do {
                guard let nsec = KeychainService.loadNsec(forNpub: request.signerNpub) else {
                    throw WristApprovalError.nsecUnavailable
                }
                let privKeyHex = try NostrKeyService.privateKeyHexFromNsec(nsec)
                let pubKeyHex = try NostrKeyService.publicKeyHexFromNpub(request.signerNpub)
                try await NostrDMService().sendDM(
                    privateKeyHex: privKeyHex,
                    publicKeyHex: pubKeyHex,
                    recipientPubkeyHex: request.replyToHex,
                    message: request.replyContent,
                    pinnedRelay: request.pinnedRelay
                )
                TrafficLogger.shared.log(.outbound, label: "Wrist Approve", detail: "approval delivered on \(request.pinnedRelay.absoluteString)", npub: request.signerNpub)
            } catch {
                TrafficLogger.shared.log(.error, label: "Wrist Approve", detail: "approval send failed: \(error.localizedDescription)", npub: request.signerNpub)
                Self.postApprovalFailureNotification()
            }
            finish()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(25))
            work.cancel()
            finish()
        }
    }

    /// The approval couldn't be sent from the background — tell the user so
    /// the request isn't silently lost (the challenge stays approvable
    /// in-app until it expires).
    @MainActor
    private static func postApprovalFailureNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Approval failed"
        content.body = "Open Pricing Studio to approve the request."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "proof-approve-failed-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        ))
    }
}

/// Carries the notification-center completion block across the actor hop.
/// UNUserNotificationCenter accepts the call from any thread; the block is
/// invoked exactly once, so the unchecked transfer is sound.
private struct SendableCompletion: @unchecked Sendable {
    let run: () -> Void
}

private enum WristApprovalError: LocalizedError {
    case nsecUnavailable

    var errorDescription: String? {
        switch self {
        case .nsecUnavailable:
            return "signing key unavailable (device not yet unlocked since restart?)"
        }
    }
}
