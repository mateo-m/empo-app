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

        // StoreKit sends no update when a subscription runs out. The app
        // sees the end at its next refresh.
        try session.expireSubscription(productIdentifier: PlusStore.productID)
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
