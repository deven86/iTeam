import Foundation
import StoreKit

/// Paid modules with StoreKit 2. Purchases are verified on the device — no server.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    static let careProductID = "com.jondhale.iteam.care.monthly"
    static let proProductID = "com.jondhale.iteam.pro.monthly"
    static let allProducts = [careProductID, proProductID]

    @Published private(set) var active: Set<String> = []
    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var isSandbox = false
    @Published private(set) var testUnlocked: Set<String>
    @Published var lastError: String?
    /// The app owner (super user): every module free on his Apple ID. See Owner.swift.
    @Published private(set) var isOwner = false

    private var updates: Task<Void, Never>?

    private init() {
        testUnlocked = Set(UserDefaults.standard.stringArray(forKey: "store.testUnlocked") ?? [])
        if UserDefaults.standard.bool(forKey: "care.testUnlock") { testUnlocked.insert(Self.careProductID) }
        isOwner = Owner.storedMatch()
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task {
            await refresh()
            await loadProducts()
            if let app = try? await AppTransaction.shared, case .verified(let a) = app {
                isSandbox = a.environment != .production
            }
            if isOwner, !(await Owner.stillAuthorized()) { isOwner = false }
        }
    }

    /// Subscribed, the owner, or — in TestFlight/sandbox builds only — unlocked for testing.
    func isUnlocked(_ productID: String) -> Bool {
        isOwner || active.contains(productID) || (isSandbox && testUnlocked.contains(productID))
    }

    func setOwner(_ on: Bool) { isOwner = on }

    var careUnlocked: Bool { isUnlocked(Self.careProductID) }
    var proUnlocked: Bool { isUnlocked(Self.proProductID) }

    func setTestUnlock(_ productID: String, _ on: Bool) {
        if on { testUnlocked.insert(productID) } else { testUnlocked.remove(productID) }
        UserDefaults.standard.set(Array(testUnlocked), forKey: "store.testUnlocked")
    }

    func refresh() async {
        var now: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.revocationDate == nil { now.insert(t.productID) }
        }
        active = now
    }

    func loadProducts() async {
        let list = (try? await Product.products(for: Self.allProducts)) ?? []
        products = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    func purchase(_ productID: String) async {
        lastError = nil
        if products[productID] == nil { await loadProducts() }
        guard let product = products[productID] else {
            lastError = "This subscription isn't on sale yet — it must first be set up in App Store Connect."
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
