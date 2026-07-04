import CloudKit
import CoreData
import SwiftData
import XCTest
@testable import PricingStudio

/// One-shot developer tool, not a regression test: uploads the SwiftData
/// mirroring schema (the CD_* record types) to the CloudKit container's
/// DEVELOPMENT environment. Production refuses runtime schema creation, so
/// until this has run once — followed by "Deploy Schema Changes to
/// Production" in the CloudKit Console — TestFlight builds cannot sync
/// entities between devices.
///
/// Gated behind an environment variable so the regular suite never performs
/// network I/O. Invoke deliberately:
///
///   TEST_RUNNER_INITIALIZE_CK_SCHEMA=1 xcodebuild test … \
///     -only-testing:PricingStudioTests/CloudKitSchemaInitTests
final class CloudKitSchemaInitTests: XCTestCase {

    func testInitializeCloudKitSchema() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["INITIALIZE_CK_SCHEMA"] == "1",
            "Schema init is a manual developer action; set TEST_RUNNER_INITIALIZE_CK_SCHEMA=1 to run"
        )

        // Bridge the app's SwiftData schema (PricingStudioApp.AppModelContainer)
        // to the Core Data model that NSPersistentCloudKitContainer needs.
        let model = try XCTUnwrap(
            NSManagedObjectModel.makeManagedObjectModel(
                for: [Operator.self, Patron.self, Authority.self, Contact.self, Campaign.self]
            ),
            "SwiftData → NSManagedObjectModel bridge produced nil"
        )

        // A throwaway store: schema init needs a loaded store but its contents
        // are irrelevant — the upload is driven by the model, not the data.
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-schema-init.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        let description = NSPersistentStoreDescription(url: storeURL)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: "iCloud.com.tollbooth.dpyc.PricingStudio"
        )

        let container = NSPersistentCloudKitContainer(
            name: "PricingStudio", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]

        let loaded = expectation(description: "store loaded")
        nonisolated(unsafe) var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 30)
        XCTAssertNil(loadError, "store load failed: \(String(describing: loadError))")

        // Uploads every record type to the Development environment and
        // dry-runs a save against each. Throws with a CKError if the
        // simulator lacks an iCloud session or the network is unreachable.
        try container.initializeCloudKitSchema(options: [])
    }
}
