import Foundation
import StoreKit

/// iLife Care subscription with StoreKit 2. Purchases are verified on the device — no server.
/// The person who creates care profiles needs the subscription; family members they share with use them free.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    static let careProductID = "com.jondhale.iteam.care.monthly"

    @Published private(set) var careActive = false
    @Published private(set) var product: Product?
    @Published private(set) var isSandbox = false
    @Published var testUnlock: Bool {
        didSet { UserDefaults.standard.set(testUnlock, forKey: "care.testUnlock") }
    }
    @Published var lastError: String?

    private var updates: Task<Void, Never>?

    private init() {
        testUnlock = UserDefaults.standard.bool(forKey: "care.testUnlock")
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task {
            await refresh()
            await loadProduct()
            if let app = try? await AppTransaction.shared, case .verified(let a) = app {
                isSandbox = a.environment != .production
            }
        }
    }

    /// Subscribed — or, in TestFlight/sandbox builds only, unlocked for testing.
    var careUnlocked: Bool { careActive || (isSandbox && testUnlock) }

    func refresh() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.careProductID, t.revocationDate == nil {
                active = true
            }
        }
        careActive = active
    }

    func loadProduct() async {
        product = try? await Product.products(for: [Self.careProductID]).first
    }

    func purchase() async {
        lastError = nil
        if product == nil { await loadProduct() }
        guard let product else {
            lastError = "The subscription isn't available yet. It must be set up in App Store Connect first."
            return
        }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let t) = verification { await t.finish() }
                await refresh()
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }
}
