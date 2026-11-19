import SwiftUI
import StoreKit

/// ✓ next to a name: iTeam Plus supporters.
struct PlusBadge: View {
    var size: CGFloat = 13
    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white, Color(hex: 0x1D9BF0))
            .accessibilityLabel("iTeam Plus")
    }
}

/// iTeam Plus: a monthly supporter badge (₹99 / $0.99). It is not identity verification.
struct PlusView: View {
    @ObservedObject private var store = Store.shared
    @EnvironmentObject var engine: SyncEngine
    @Environment(\.look) private var look
    @State private var busy = false
    @State private var redeem = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Text(engine.myName).font(.title2.bold())
                        PlusBadge(size: 22)
                    }
                    Text(store.hasPlus ? "You're an iTeam Plus member. Thank you for supporting iTeam!" : "Show the blue ✓ next to your name everywhere in iTeam.")
                        .multilineTextAlignment(.center).foregroundStyle(look.textSecondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            Section("What you get") {
                Label("Blue ✓ next to your name in chats, groups, Rooms and Views", systemImage: "checkmark.seal.fill")
                Label("Supports a private app with no ads and no data selling", systemImage: "heart.fill")
                Label("Cancel anytime in your Apple ID subscriptions", systemImage: "arrow.uturn.backward.circle")
            }
            if !store.hasPlus {
                Section {
                    Button {
                        busy = true
                        Task { await store.purchase(Store.plusProductID); busy = false }
                    } label: {
                        HStack {
                            Text("Get iTeam Plus — \(store.products[Store.plusProductID]?.displayPrice ?? "₹99") / month").bold()
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                    .disabled(busy)
                    Button("Redeem a code") { redeem = true }
                    if let e = store.lastError { Text(e).font(.caption).foregroundStyle(look.warning) }
                } footer: {
                    Text("iTeam Plus is a supporter badge. It does not verify identity.")
                }
            }
        }
        .lookScreen()
        .navigationTitle("iTeam Plus")
        .offerCodeRedemption(isPresented: $redeem)
    }
}
