import SwiftUI

/// The checkout mode's frame, on the Purse styling reference. Same bones as `DemoScreen`, minus the
/// wizard: a shopper is not on "step 2 of 3", they are on a page called Payment.
struct CheckoutScreen<Content: View, Action: View>: View {
    let title: String
    var subtitle: String?
    var onBack: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var bottomAction: () -> Action

    var body: some View {
        VStack(spacing: 0) {
            CheckoutHeader(title: title, subtitle: subtitle, onBack: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: PurseDS.Space.l) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PurseDS.Space.l)
                    .padding(.vertical, PurseDS.Space.xl)
            }
            VStack { bottomAction() }
                .padding(.horizontal, PurseDS.Space.l)
                .padding(.top, PurseDS.Space.m)
                .padding(.bottom, PurseDS.Space.s)
                .background(PurseDS.surface)
                // A bottom bar lifts off the page rather than sitting behind a divider.
                .shadow(color: PurseDS.sheetShadow, radius: 24, x: 0, y: -8)
        }
        .background(PurseDS.surfaceMuted)
    }
}

struct CheckoutHeader: View {
    let title: String
    var subtitle: String?
    var onBack: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: PurseDS.Space.m) {
            if let onBack {
                Button(action: onBack) {
                    PurseIcon("arrow-left", size: 24)
                        .frame(width: PurseDS.minTapTarget, height: PurseDS.minTapTarget, alignment: .leading)
                }
                .foregroundStyle(PurseDS.ink)
                .accessibilityLabel("Back")
            }
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle {
                    Text(subtitle)
                        .font(PurseDS.regular(PurseDS.Size.caption))
                        .foregroundStyle(PurseDS.textSubtle)
                }
                Text(title)
                    .font(PurseDS.semibold(PurseDS.Size.heading))
                    .tracking(-0.01 * PurseDS.Size.heading)
                    .foregroundStyle(PurseDS.ink)
            }
            Spacer()
        }
        .padding(.horizontal, PurseDS.Space.l)
        .padding(.vertical, PurseDS.Space.m)
        .background(PurseDS.surfaceMuted)
    }
}

/// One line of the basket.
struct LineItemRow: View {
    let item: CartItem
    let currency: String

    var body: some View {
        HStack(alignment: .center, spacing: PurseDS.Space.m) {
            // No product photography ships with this demo, so the placeholder is honest about it
            // rather than pulling an image off the network.
            RoundedRectangle(cornerRadius: PurseDS.Radius.control)
                .fill(PurseDS.surfaceMuted)
                .frame(width: 48, height: 48)
                .overlay(PurseIcon(item.icon, size: 20).foregroundStyle(PurseDS.textSubtle))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(PurseDS.regular(PurseDS.Size.body))
                    .foregroundStyle(PurseDS.ink)
                Text("Quantity \(item.quantity)")
                    .font(PurseDS.regular(PurseDS.Size.caption))
                    .foregroundStyle(PurseDS.textSubtle)
            }
            Spacer()
            Text(amountText(item.lineTotal, currency))
                .font(PurseDS.semibold(PurseDS.Size.body))
                .foregroundStyle(PurseDS.ink)
        }
    }
}

/// Subtotal, shipping, total. The total is the one a shopper checks against their bank app, so it
/// is the largest thing on the card.
struct OrderSummary: View {
    let subtotal: Decimal
    let currency: String
    /// The session's amount once one exists — the authority, whatever the basket adds up to.
    var sessionAmount: Decimal?

    var body: some View {
        VStack(spacing: PurseDS.Space.s) {
            SummaryLine(label: "Subtotal", value: amountText(subtotal, currency))
            SummaryLine(label: "Shipping", value: "Free")
            Rectangle().fill(PurseDS.border).frame(height: 1).padding(.vertical, PurseDS.Space.xs)
            HStack {
                Text("Total")
                    .font(PurseDS.semibold(PurseDS.Size.bodyLarge))
                    .foregroundStyle(PurseDS.ink)
                Spacer()
                Text(amountText(sessionAmount ?? subtotal, currency))
                    .font(PurseDS.semibold(PurseDS.Size.title))
                    .tracking(-0.01 * PurseDS.Size.title)
                    .foregroundStyle(PurseDS.ink)
            }
            if let sessionAmount, sessionAmount != subtotal {
                // The basket is a fixed prop; the amount that will actually be charged comes from
                // the session alfred minted. When they disagree, the session wins and says so.
                Text("The charged amount comes from the payment session, not this basket.")
                    .font(PurseDS.regular(PurseDS.Size.caption))
                    .foregroundStyle(PurseDS.textSubtle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct SummaryLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(PurseDS.textSecondary)
            Spacer()
            Text(value).foregroundStyle(PurseDS.ink)
        }
        .font(PurseDS.regular(PurseDS.Size.body))
    }
}

/// A fixed basket. No quantity editing, no persistence — it exists to give the payment an origin a
/// shopper recognises, not to be a store.
struct CartItem: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let quantity: Int
    let unitPrice: Decimal

    var lineTotal: Decimal { unitPrice * Decimal(quantity) }

    static let sample: [CartItem] = [
        CartItem(name: "Merino crew jumper", icon: "shirt", quantity: 1, unitPrice: 89.00),
        CartItem(name: "Canvas weekend bag", icon: "briefcase", quantity: 1, unitPrice: 129.00),
        CartItem(name: "Wool socks, three pack", icon: "footprints", quantity: 2, unitPrice: 12.50)
    ]

    static var sampleSubtotal: Decimal {
        sample.reduce(0) { $0 + $1.lineTotal }
    }
}
