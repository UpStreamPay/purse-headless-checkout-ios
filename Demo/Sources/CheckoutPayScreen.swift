import PurseHeadlessCheckout
import SwiftUI
import WebKit

/// The pay screen a shopper would actually see: same SDK calls as `PayScreen`, no developer chrome.
struct CheckoutPayScreen: View {
    @ObservedObject var controller: DemoController

    private var checkout: PurseHeadlessCheckout? { controller.checkout }

    var body: some View {
        ZStack {
            CheckoutScreen(
                title: "Payment",
                subtitle: "Step 2 of 2",
                onBack: controller.backToCart
            ) {
                if let checkout {
                    PurseCard {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Total to pay")
                                .font(PurseDS.regular(PurseDS.Size.body))
                                .foregroundStyle(PurseDS.textSecondary)
                            Spacer()
                            Text(amountText(checkout.session.amount, checkout.currency))
                                .font(PurseDS.semibold(PurseDS.Size.heading))
                                .tracking(-0.01 * PurseDS.Size.heading)
                                .foregroundStyle(PurseDS.ink)
                        }
                        if checkout.isPaymentFulfilled {
                            Text("Fully covered")
                                .font(PurseDS.regular(PurseDS.Size.caption))
                                .foregroundStyle(PurseDS.success)
                        } else if checkout.remainingAmountToPay != checkout.session.amount {
                            Text("Left to pay \(amountText(checkout.remainingAmountToPay, checkout.currency))")
                                .font(PurseDS.regular(PurseDS.Size.caption))
                                .foregroundStyle(PurseDS.textSecondary)
                        }
                    }

                    if !controller.expressMethods.isEmpty {
                        PurseSectionTitle("Express checkout")
                        // No cards: these ship their own styled button. Klarna is absent on purpose
                        // — its surface pays through the shared Pay button, not its own.
                        ForEach(controller.expressMethods, id: \.id) { item in
                            PaymentElementView(controller.element(for: item))
                                .frame(height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: PurseDS.Radius.control))
                                .id(item.id)
                        }
                    }

                    if !checkout.paymentTokens.isEmpty {
                        PurseSectionTitle("Your saved cards")
                        ForEach(checkout.paymentTokens, id: \.id) { token in
                            ShopperRow(controller: controller, item: .paymentToken(token))
                        }
                    }

                    if !controller.payableMethods.isEmpty {
                        PurseSectionTitle("Pay another way")
                        ForEach(controller.payableMethods, id: \.id) { item in
                            ShopperRow(controller: controller, item: item)
                        }
                    }

                    if !checkout.savedSecondaryTokens.isEmpty {
                        PurseSectionTitle("Your gift cards")
                        ForEach(checkout.savedSecondaryTokens, id: \.id) { token in
                            SavedGiftCard(controller: controller, token: token)
                        }
                    }

                    if !controller.giftCardMethods.isEmpty {
                        PurseSectionTitle("Use a gift card")
                        ForEach(controller.giftCardMethods, id: \.id) { method in
                            ShopperGiftCardRow(controller: controller, method: method)
                        }
                    }
                }
            } bottomAction: {
                PurseButton(title: payTitle, enabled: controller.canPay) { controller.submit() }
            }

            if controller.submitting { CheckoutBusyOverlay() }
        }
    }

    private var payTitle: String {
        guard let checkout, checkout.remainingAmountToPay > 0 else { return "Pay" }
        return "Pay \(amountText(checkout.remainingAmountToPay, checkout.currency))"
    }
}

private struct ShopperRow: View {
    @ObservedObject var controller: DemoController
    let item: PaymentItem

    private var selected: Bool { controller.selectedItemId == item.id }

    var body: some View {
        PurseCard(selected: selected) {
            Button {
                controller.select(selected ? nil : item)
            } label: {
                HStack(spacing: PurseDS.Space.m) {
                    PurseIcon(selected ? "circle-dot" : "circle", size: 20)
                        .foregroundStyle(selected ? PurseDS.accent : PurseDS.textSubtle)
                    MethodBadge(url: controller.iconURL(for: item))
                        .frame(width: 32, height: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.shopperLabel(item))
                            .font(PurseDS.regular(PurseDS.Size.body))
                            .foregroundStyle(PurseDS.ink)
                        if let detail = controller.shopperDetail(item) {
                            Text(detail)
                                .font(PurseDS.regular(PurseDS.Size.caption))
                                .foregroundStyle(PurseDS.textSubtle)
                        }
                    }
                    Spacer()
                }
                .frame(minHeight: PurseDS.minTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let expansion { expansion }
        }
    }

    /// `nil` when selecting this row reveals nothing, so the card keeps the height it already had.
    private var expansion: ShopperElementBody? {
        guard selected else { return nil }
        guard ShopperElementBody.hasContent(controller.element(for: item), item) else { return nil }
        return ShopperElementBody(controller: controller, item: item)
    }
}

private struct ShopperElementBody: View {
    @ObservedObject var controller: DemoController
    let item: PaymentItem

    var body: some View {
        let element = controller.element(for: item)
        VStack(alignment: .leading, spacing: PurseDS.Space.m) {
            if let helper = Self.helperText(element, item) {
                Text(helper)
                    .font(PurseDS.regular(PurseDS.Size.caption))
                    .foregroundStyle(PurseDS.textSecondary)
            }
            if element.hasUI {
                PaymentElementView(element).id(item.id)
            } else if !element.isReady {
                HStack(spacing: PurseDS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Getting things ready…")
                        .font(PurseDS.regular(PurseDS.Size.caption))
                        .foregroundStyle(PurseDS.textSubtle)
                }
            }
            if case let .primaryMethod(method) = item, method.simulable {
                SimulationPreview(controller: controller, method: method)
            }
        }
    }

    /// Whether ``body`` would draw anything: an empty container still costs the card its spacing,
    /// so the row grows for nothing. Kept beside `body` — the two must agree.
    static func hasContent(_ element: PaymentElement, _ item: PaymentItem) -> Bool {
        if helperText(element, item) != nil { return true }
        if element.hasUI { return true }
        if !element.isReady { return true }
        if case let .primaryMethod(method) = item, method.simulable { return true }
        return false
    }

    static func helperText(_ element: PaymentElement, _ item: PaymentItem) -> String? {
        if case let .paymentToken(token) = item {
            return token.requiresCVV ? "Enter this card's security code to pay with it." : nil
        }
        if !element.hasUI {
            return "You'll finish this payment on the provider's own page, then come back here."
        }
        return nil
    }
}

/// The CDN badge, in a `WKWebView` because the badges are **SVG** and neither `UIImage` nor
/// `AsyncImage` decodes that — `AsyncImage` shows an empty placeholder forever. WebKit is already
/// linked for redirects; a real merchant would add an SVG library rather than a web view per row.
private struct MethodBadge: UIViewRepresentable {
    let url: String

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        // Interaction belongs to the row behind it, not to the badge.
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard let url = URL(string: url), context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        view.loadHTMLString(
            """
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
            <body style="margin:0;display:flex;align-items:center;justify-content:center;height:100%">
            <img src="\(url.absoluteString)" style="max-width:100%;max-height:100%">
            </body></html>
            """,
            baseURL: url
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loaded: URL?
    }
}

private struct SavedGiftCard: View {
    @ObservedObject var controller: DemoController
    let token: SavedSecondaryToken

    var body: some View {
        PurseCard {
            HStack(spacing: PurseDS.Space.m) {
                PurseIcon("gift", size: 20).foregroundStyle(PurseDS.textSubtle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(token.name.isEmpty ? "Gift card" : token.name)
                        .font(PurseDS.regular(PurseDS.Size.body))
                        .foregroundStyle(PurseDS.ink)
                    Text(status)
                        .font(PurseDS.regular(PurseDS.Size.caption))
                        .foregroundStyle(PurseDS.textSubtle)
                }
                Spacer()
                if token.disabled == nil && token.balanceResolved {
                    PurseSecondaryButton(title: "Use") { controller.useSaved(token) }
                        .frame(width: 88)
                }
            }
        }
    }

    private var status: String {
        if token.disabled != nil { return "Unavailable right now" }
        guard token.balanceResolved else { return "Checking balance…" }
        return "Balance \(amountText(token.balance, controller.checkout?.currency ?? ""))"
    }
}

/// Gift cards, shopper-side: the playground's row without the registration controls.
private struct ShopperGiftCardRow: View {
    @ObservedObject var controller: DemoController
    let method: SecondaryMethod

    var body: some View {
        let state = controller.giftCard(method)
        PurseCard {
            HStack(spacing: PurseDS.Space.s) {
                PurseIcon("gift", size: 20).foregroundStyle(PurseDS.textSubtle)
                Text("Gift card")
                    .font(PurseDS.regular(PurseDS.Size.body))
                    .foregroundStyle(PurseDS.ink)
            }
            Text("Test card 9250004781234567890, security code 123.")
                .font(PurseDS.regular(PurseDS.Size.caption))
                .foregroundStyle(PurseDS.textSubtle)

            PurseField(
                placeholder: "Card number",
                text: Binding(
                    get: { state.pan },
                    set: { value in controller.updateGiftCard(method) { $0.pan = value } }
                ),
                keyboard: .numberPad
            )

            if controller.requiresCVV(method, pan: state.pan) {
                PurseField(
                    placeholder: "Security code",
                    text: Binding(
                        get: { state.cvv },
                        set: { value in controller.updateGiftCard(method) { $0.cvv = value } }
                    ),
                    secure: true,
                    keyboard: .numberPad
                )
            }

            if let token = state.token {
                Text("Balance \(amountText(token.balance, controller.checkout?.currency ?? ""))")
                    .font(PurseDS.regular(PurseDS.Size.caption))
                    .foregroundStyle(PurseDS.textSecondary)
                if let applied = state.applied {
                    HStack {
                        Text("Applied \(amountText(applied, controller.checkout?.currency ?? ""))")
                            .font(PurseDS.regular(PurseDS.Size.caption))
                            .foregroundStyle(PurseDS.success)
                        Spacer()
                        PurseSecondaryButton(title: "Remove") { controller.removeGiftCard(method) }
                            .frame(width: 104)
                    }
                } else {
                    PurseSecondaryButton(title: "Apply to this order") {
                        controller.applyGiftCard(method)
                    }
                }
            } else {
                PurseSecondaryButton(
                    title: "Check balance",
                    loading: state.checking,
                    enabled: !state.pan.isEmpty
                ) {
                    controller.checkBalance(method)
                }
            }

            if let error = state.error {
                Text(error)
                    .font(PurseDS.regular(PurseDS.Size.caption))
                    .foregroundStyle(PurseDS.danger)
            }
        }
    }
}

private struct CheckoutBusyOverlay: View {
    var body: some View {
        ZStack {
            PurseDS.ink.opacity(0.5).ignoresSafeArea()
            VStack(spacing: PurseDS.Space.m) {
                ProgressView().controlSize(.large).tint(PurseDS.ink)
                Text("Taking your payment…")
                    .font(PurseDS.regular(PurseDS.Size.body))
                    .foregroundStyle(PurseDS.ink)
            }
            .padding(PurseDS.Space.xl)
            .background(PurseDS.surface)
            .clipShape(RoundedRectangle(cornerRadius: PurseDS.Radius.sheet))
            .shadow(color: PurseDS.sheetShadow, radius: 24, x: 0, y: 8)
        }
    }
}
