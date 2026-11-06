import Foundation
import Observation
import StoreKit

/// The Empo Plus subscription on the App Store. StoreKit checks the
/// signature of each transaction on the device, so no server takes part.
@MainActor
@Observable
final class PlusStore {

    static let shared = PlusStore()

    static let productID = "sh.mateo.empo.plus.monthly"

    enum PurchaseFailure: Error {
        case cancelled
        case pending
        case failed
    }

    private(set) var product: Product?
    private(set) var isSubscribed = false
    private var lastRefresh: Task<Void, Never>?

    private init() {
        // A renewal, a refund, or a purchase on another device of the
        // same Apple Account arrives here, also while the app is closed.
        Task {
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await refresh()
            }
        }
    }

    /// Each refresh starts after the one before it ends, so the last
    /// refresh to start always sets the state.
    func refresh() async {
        let previous = lastRefresh
        let refresh = Task {
            await previous?.value
            var subscribed = false
            for await entitlement in Transaction.currentEntitlements(for: Self.productID) {
                if case .verified(let transaction) = entitlement, transaction.revocationDate == nil {
                    subscribed = true
                }
            }
            isSubscribed = subscribed
        }
        lastRefresh = refresh
        await refresh.value
    }

    func loadProduct() async {
        guard product == nil else { return }
        product = try? await Product.products(for: [Self.productID]).first
    }

    func purchase() async throws(PurchaseFailure) {
        guard let product else { throw .failed }
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            throw .failed
        }
        switch result {
        case .success(.verified(let transaction)):
            await transaction.finish()
            await refresh()
        case .success(.unverified):
            throw .failed
        case .userCancelled:
            throw .cancelled
        case .pending:
            // Ask to Buy, or a payment that needs an action. The answer
            // arrives through `Transaction.updates`.
            throw .pending
        @unknown default:
            throw .failed
        }
    }

    /// Returns false when the App Store did not answer.
    func restore() async -> Bool {
        do {
            try await AppStore.sync()
        } catch {
            return false
        }
        await refresh()
        return true
    }
}
