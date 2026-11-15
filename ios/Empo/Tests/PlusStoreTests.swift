import StoreKit
import StoreKitTest
import XCTest

@testable import Empo

@MainActor
final class PlusStoreTests: XCTestCase {

    private var session: SKTestSession!

    // On a Simulator that never ran these tests, the 3 tests fail on the
    // first run. The app starts before the session puts the StoreKit file
    // on the Simulator, so StoreKit sends the app to the sandbox for that
    // whole run. Xcode loads the file before launch only for Run, not
    // for Test.
    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "Empo")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        await PlusStore.shared.refresh()
    }

    override func tearDown() async throws {
        session.clearTransactions()
        await PlusStore.shared.refresh()
    }

    func testAPurchaseGivesPlus() async throws {
        let store = PlusStore.shared
        XCTAssertFalse(store.isSubscribed)
        await store.loadProduct()
        XCTAssertEqual(store.product?.id, PlusStore.productID)

        try await store.purchase()

        XCTAssertTrue(store.isSubscribed)
        XCTAssertTrue(EmpoPlus.shared.hasPlus)
    }

    func testAnEndedSubscriptionTakesPlusAway() async throws {
        let store = PlusStore.shared
        await store.loadProduct()
        try await store.purchase()
        XCTAssertTrue(store.isSubscribed)

        // On Xcode 27.2, expireSubscription(productIdentifier:) leaves the
        // expiry date of the transaction 1 month away. A purchase dated
        // 2 months ago that never renews gives a subscription that ended.
        session.clearTransactions()
        let start = try XCTUnwrap(Calendar.current.date(byAdding: .month, value: -2, to: .now))
        let ended = try await session.buyProduct(
            identifier: PlusStore.productID,
            options: [.purchaseDate(start, renewalBehavior: .cancelImmediately)])
        XCTAssertLessThan(try XCTUnwrap(ended.expirationDate), .now)

        // StoreKit sends no update when a subscription runs out. The app
        // sees the end at its next refresh.
        await store.refresh()

        var left: [String] = []
        for await entitlement in Transaction.currentEntitlements(for: PlusStore.productID) {
            let transaction = entitlement.unsafePayloadValue
            left.append(
                "id \(transaction.id), bought \(transaction.purchaseDate), "
                    + "ends \(transaction.expirationDate.map { "\($0)" } ?? "never"), "
                    + "revoked \(transaction.revocationDate.map { "\($0)" } ?? "no")")
        }
        XCTAssertFalse(
            store.isSubscribed,
            "the ended purchase is id \(ended.id). StoreKit still gives: \(left)")
    }

    func testARefundTakesPlusAway() async throws {
        let store = PlusStore.shared
        await store.loadProduct()
        let listener = Task { @MainActor in
            for await update in Transaction.updates {
                let t = update.unsafePayloadValue
                self.probe("test listener: id \(t.id) revoked \(t.revocationDate != nil)")
            }
        }
        defer { listener.cancel() }
        var failures = 0
        for cycle in 0..<4 {
            if cycle > 0 {
                session.clearTransactions()
                await store.refresh()
            }
            try await store.purchase()
            let transaction = try XCTUnwrap(session.allTransactions().first)
            probe("cycle \(cycle): bought id \(transaction.identifier), store \(store.isSubscribed)")
            probeZero = .now
            try session.refundTransaction(identifier: UInt(transaction.identifier))
            probe("cycle \(cycle): refundTransaction returned")
            var lastSeen = ""
            var storeEnded = false
            for _ in 0..<30 {
                var seen: [String] = []
                for await e in Transaction.currentEntitlements(for: PlusStore.productID) {
                    let t = e.unsafePayloadValue
                    seen.append("id \(t.id) revoked \(t.revocationDate != nil)")
                }
                let now = "entitlements \(seen), store \(store.isSubscribed)"
                if now != lastSeen { probe("cycle \(cycle): \(now)") }
                lastSeen = now
                if !store.isSubscribed {
                    storeEnded = true
                    break
                }
                try await Task.sleep(for: .seconds(1))
            }
            if !storeEnded {
                failures += 1
                await store.refresh()
                probe("cycle \(cycle): no end in 30 s, after a direct refresh: store \(store.isSubscribed)")
            }
        }
        XCTAssertEqual(failures, 0)
    }

    private var probeZero = ContinuousClock.now

    private func probe(_ line: String) {
        let t = (ContinuousClock.now - probeZero).components
        NSLog("REFUNDPROBE +%.2fs %@", Double(t.seconds) + Double(t.attoseconds) / 1e18, line)
    }

    private func watchUntilNotSubscribed(_ store: PlusStore, _ done: XCTestExpectation) {
        withObservationTracking {
            _ = store.isSubscribed
        } onChange: {
            Task { @MainActor in
                if store.isSubscribed { self.watchUntilNotSubscribed(store, done) } else { done.fulfill() }
            }
        }
    }
}
