import PurseHeadlessCheckout
import SwiftUI

struct PayScreen: View {
    @ObservedObject var controller: DemoController

    private var checkout: PurseHeadlessCheckout? { controller.checkout }

    var body: some View {
        ZStack {
            DemoScreen(step: 2, title: "Pay", onBack: controller.back) {
                if let checkout {
                    AmountHeader(checkout: checkout)

                    SmallButton(
                        text: "Refresh session (new cart)",
                        loading: controller.refreshingSession
                    ) { controller.refreshSession() }

                    if !controller.expressMethods.isEmpty {
                        SectionTitle("Express checkout")
                        // Always mounted: these render their own branded button and pay from its tap.
                        ForEach(controller.expressMethods, id: \.id) { item in
                            DemoCard {
                                PaymentElementView(controller.element(for: item))
                                    .frame(height: 52)
                                    .id(item.id)
                                Text(controller.label(item)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !checkout.paymentTokens.isEmpty {
                        SectionTitle("Saved cards")
                        ForEach(checkout.paymentTokens, id: \.id) { token in
                            SelectableRow(controller: controller, item: .paymentToken(token))
                        }
                    }

                    if !controller.payableMethods.isEmpty {
                        SectionTitle("Choose how to pay")
                        ForEach(controller.payableMethods, id: \.id) { item in
                            SelectableRow(controller: controller, item: item)
                        }
                    }

                    if !checkout.savedSecondaryTokens.isEmpty {
                        SectionTitle("Your saved gift cards")
                        ForEach(checkout.savedSecondaryTokens, id: \.id) { token in
                            SavedGiftCardRow(controller: controller, token: token)
                        }
                    }

                    if !controller.giftCardMethods.isEmpty {
                        SectionTitle("Gift card")
                        Text("Test card 9250004781234567890, CVC 123.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(controller.giftCardMethods, id: \.id) { method in
                            GiftCardRow(controller: controller, method: method)
                        }
                    }

                    EventLog(events: controller.events)
                }
            } bottomAction: {
                BigButton(text: payTitle) { controller.submit() }
            }

            if controller.submitting { BusyOverlay() }
        }
    }

    private var payTitle: String {
        guard let checkout else { return "Pay" }
        guard checkout.remainingAmountToPay > 0 else { return "Pay" }
        return "Pay \(amountText(checkout.remainingAmountToPay, checkout.currency))"
    }
}

private struct AmountHeader: View {
    let checkout: PurseHeadlessCheckout

    var body: some View {
        DemoCard(tinted: true) {
            Text(amountText(checkout.session.amount, checkout.currency))
                .font(.largeTitle.weight(.semibold))
            if checkout.isPaymentFulfilled {
                Text("Fully covered").font(.subheadline).foregroundStyle(DemoTheme.success)
            } else {
                Text("Left to pay \(amountText(checkout.remainingAmountToPay, checkout.currency))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(checkout.amountSplit.enumerated()), id: \.offset) { _, split in
                Text(amountText(split.amount, checkout.currency)).font(DemoTheme.mono)
            }
        }
    }
}

private struct SelectableRow: View {
    @ObservedObject var controller: DemoController
    let item: PaymentItem

    private var selected: Bool { controller.selectedItemId == item.id }

    var body: some View {
        DemoCard(selected: selected) {
            Button {
                controller.select(selected ? nil : item)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.label(item)).font(.body)
                        Text(controller.subtitle(item)).font(DemoTheme.mono).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(selected ? "▾" : "▸").font(DemoTheme.mono)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tint(DemoTheme.accentTint)

            if selected { ElementBody(controller: controller, item: item) }
        }
    }
}

private struct ElementBody: View {
    @ObservedObject var controller: DemoController
    let item: PaymentItem

    var body: some View {
        let element = controller.element(for: item)
        VStack(alignment: .leading, spacing: 12) {
            if let helper = helperText(element) {
                Text(helper).font(.footnote).foregroundStyle(.secondary)
            }
            if element.hasUI {
                PaymentElementView(element).id(item.id)
            } else {
                Text(element.isReady ? "Ready — tap Pay to continue." : "Preparing…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if case let .primaryMethod(method) = item, method.simulable {
                SimulationPreview(controller: controller, method: method)
            }
        }
    }

    private func helperText(_ element: PaymentElement) -> String? {
        if case let .paymentToken(token) = item {
            return token.requiresCVV
                ? "Enter this card's security code to pay with it."
                : "No security code needed — tap Pay."
        }
        if !element.hasUI {
            return "No form to fill in — tapping Pay opens this provider's own page, then brings you back."
        }
        return nil
    }
}

private struct SavedGiftCardRow: View {
    @ObservedObject var controller: DemoController
    let token: SavedSecondaryToken

    var body: some View {
        DemoCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(token.name.isEmpty ? token.id : token.name)
                    Text(status).font(DemoTheme.mono).foregroundStyle(.secondary)
                }
                Spacer()
                if token.disabled == nil && token.balanceResolved {
                    SmallButton(text: "Use") { controller.useSaved(token) }.frame(width: 90)
                }
            }
        }
    }

    private var status: String {
        if let disabled = token.disabled { return "unavailable (\(disabled.code.rawValue))" }
        guard token.balanceResolved else { return "checking balance…" }
        let currency = controller.checkout?.currency ?? ""
        return "balance \(amountText(token.balance, currency))"
    }
}

private struct GiftCardRow: View {
    @ObservedObject var controller: DemoController
    let method: SecondaryMethod

    var body: some View {
        let state = controller.giftCard(method)
        DemoCard {
            Text(method.id).font(.body)

            TextField("Card number", text: Binding(
                get: { state.pan },
                set: { value in controller.updateGiftCard(method) { $0.pan = value } }
            ))
            .keyboardType(.numberPad)
            .textFieldStyle(.roundedBorder)

            if controller.requiresCVV(method, pan: state.pan) {
                SecureField("CVC", text: Binding(
                    get: { state.cvv },
                    set: { value in controller.updateGiftCard(method) { $0.cvv = value } }
                ))
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
            }

            SmallButton(text: "Check balance", loading: state.checking, enabled: !state.pan.isEmpty) {
                controller.checkBalance(method)
            }

            if let token = state.token {
                let currency = controller.checkout?.currency ?? ""
                Text("\(token.name) — balance \(amountText(token.balance, currency))")
                    .font(.footnote)

                TextField("Amount (blank = as much as needed)", text: Binding(
                    get: { state.amount },
                    set: { value in controller.updateGiftCard(method) { $0.amount = value } }
                ))
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)

                if token.canBeRegistered {
                    Toggle("Keep this card for next time", isOn: Binding(
                        get: { state.keep },
                        set: { value in controller.updateGiftCard(method) { $0.keep = value } }
                    ))
                    .font(.footnote)
                    TextField("Name (optional)", text: Binding(
                        get: { state.name },
                        set: { value in controller.updateGiftCard(method) { $0.name = value } }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                if let applied = state.applied {
                    let currency = controller.checkout?.currency ?? ""
                    HStack {
                        Text("Applied \(amountText(applied, currency))")
                            .font(.footnote)
                            .foregroundStyle(DemoTheme.success)
                        Spacer()
                        SmallButton(text: "Remove") { controller.removeGiftCard(method) }.frame(width: 110)
                    }
                } else {
                    SmallButton(text: "Add to payment") { controller.applyGiftCard(method) }
                }
            }

            if let error = state.error {
                Text(error).font(.footnote).foregroundStyle(DemoTheme.failure)
            }
        }
    }
}
