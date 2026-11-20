import StoreKit
import StoreKitTest
import XCTest

@testable import Empo

@MainActor
final class PlusStoreTests: XCTestCase {

    private var session: SKTestSession!

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
        for await entitlement in Transaction.currentEntitlements {
            let transaction = entitlement.unsafePayloadValue
            guard transaction.productID == PlusStore.productID else { continue }
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
        try await store.purchase()
        let transaction = try XCTUnwrap(session.allTransactions().first)

        try session.refundTransaction(identifier: UInt(transaction.identifier))
        // `refundTransaction` returns before StoreKit shows the refund. On
        // a GitHub-hosted Mac, StoreKit sometimes sends no
        // `Transaction.updates` for the first refund of a run.
        let deadline = ContinuousClock.now + .seconds(30)
        while store.isSubscribed {
            guard ContinuousClock.now < deadline else { return XCTFail("Plus stays 30 s after a refund") }
            try await Task.sleep(for: .milliseconds(100))
            await store.refresh()
        }
    }
}
