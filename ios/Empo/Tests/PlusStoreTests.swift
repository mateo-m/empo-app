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
        session.timeRate = .oneRenewalEveryTwoSeconds
        await store.loadProduct()
        try await store.purchase()
        XCTAssertTrue(store.isSubscribed)
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.disableAutoRenewForTransaction(identifier: UInt(transaction.identifier))
        guard case .verified(let latest)? = await Transaction.latest(for: PlusStore.productID),
            let end = latest.expirationDate
        else { return XCTFail("No subscription on the device") }

        // StoreKit sends no update when a subscription runs out. The app
        // sees the end at its next refresh.
        try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow) + 0.5))
        await store.refresh()

        XCTAssertFalse(store.isSubscribed)
    }

    func testARefundTakesPlusAway() async throws {
        let store = PlusStore.shared
        await store.loadProduct()
        try await store.purchase()
        let transaction = try XCTUnwrap(session.allTransactions().first)

        let refunded = expectation(description: "Plus ends")
        watchUntilNotSubscribed(store, refunded)
        try session.refundTransaction(identifier: UInt(transaction.identifier))
        await fulfillment(of: [refunded], timeout: 10)
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
