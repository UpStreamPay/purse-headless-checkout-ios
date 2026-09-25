import Combine
import Foundation
import PurseCheckoutApplePay
import PurseCheckoutKlarna
import PurseCheckoutPayPal
import PurseHeadlessCheckout
import SwiftUI

enum DemoStep { case session, pay, result }

/// Everything the three screens read and drive. One object, like Android's `DemoController`.
@MainActor
final class DemoController: ObservableObject {

    // MARK: Mode

    /// `nil` until a mode is picked. Playground is the SDK workbench, checkout the shopper flow;
    /// both drive this one controller.
    @Published var mode: DemoMode?
    @Published var checkoutStep: CheckoutStep = .cart

    // MARK: Session

    @Published var step: DemoStep = .session
    @Published var checkout: PurseHeadlessCheckout?
    @Published var widgetData = ""
    @Published var creatingSession = false
    @Published var refreshingSession = false
    @Published var sessionError: String?
    @Published var sessionDetails = ""

    // MARK: Pay

    @Published var selectedItemId: String?
    @Published var submitting = false
    @Published var snackbar: String?
    @Published var events: [String] = []
    @Published var giftCards: [String: GiftCardState] = [:]

    // MARK: Confirmation (checkout mode)

    /// From alfred, standing in for the merchant backend: reading the session needs server
    /// credentials, which `widget.data`'s client key does not carry.
    @Published var confirmedStatus: PaymentSessionStatus?
    @Published var confirming = false
    @Published var orderReference = "PRS-\(Int.random(in: 100_000...999_999))"

    // MARK: Result

    @Published var result: DemoResult?
    @Published var alfredSessionId = ""
    @Published var transactions: [DemoJSON] = []
    @Published var rawTransactions = ""
    @Published var loadingTransactions = false
    @Published var capturePaymentId = ""
    @Published var captureAmount = ""
    @Published var captureRaw = ""
    @Published var capturing = false

    let alfred = AlfredClient(baseURL: AlfredClient.fromInfoPlist)
    var alfredBaseURL: String { alfred.baseURL }

    /// One presenter for every redirect. `prefersInAppWebView` because this demo claims no
    /// Associated Domain for `cdn.purse-dev.com`.
    private let presenter = WebAuthRedirectPresenter(
        policy: RedirectPolicy(
            returnDestination: .universalLink(host: "cdn.purse-dev.com", path: "/return/done.html")
        ),
        prefersInAppWebView: true
    )

    private var elements: [String: PaymentElement] = [:]
    private var listeners: [String: ElementSpy] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init() {
        // No `ServiceLoader` here: partner products are installed explicitly, and Apple Pay's
        // merchant id is entitlement-bound so only the app can supply it.
        PluginRegistry.shared.install(ApplePayModule(configuration: ApplePayConfiguration(
            merchantIdentifier: "merchant.com.adyen.Upstreampay871.test",
            merchantName: "Purse Demo"
        )))
        PluginRegistry.shared.install(PayPalModule())
        PluginRegistry.shared.install(KlarnaModule())
    }

    // MARK: Screen 1

    func createSession() {
        creatingSession = true
        sessionError = nil
        Task {
            do {
                let session = try await alfred.createSession()
                widgetData = session.widgetData
                if let id = session.orchestrationSessionId { alfredSessionId = id }
                initCheckout()
            } catch {
                sessionError = "\(error.localizedDescription)\n\nIs alfred running? \(alfredBaseURL)"
            }
            creatingSession = false
        }
    }

    func initCheckout() {
        sessionError = nil
        teardownCheckout()
        do {
            let checkout = try PurseHeadlessCheckout(widgetData: widgetData)
            self.checkout = checkout
            // SwiftUI only observes the object it was handed, so the checkout's changes have to be
            // forwarded.
            checkout.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
            sessionDetails = Self.summarize(checkout)
            alfredSessionId = Self.resolveAlfredSessionId(widgetData: widgetData) ?? alfredSessionId
            captureAmount = "\(checkout.session.amount)"
            log("session ready → \(checkout.currentSessionId) (\(amountText(checkout.session.amount, checkout.currency)))")
        } catch {
            sessionError = "\(error)"
        }
    }

    func goToPay() {
        guard checkout != nil else { return }
        step = .pay
    }

    // MARK: Checkout mode

    func enter(_ mode: DemoMode) {
        self.mode = mode
    }

    func startCheckout() {
        guard checkout == nil else {
            checkoutStep = .pay
            return
        }
        creatingSession = true
        sessionError = nil
        Task {
            do {
                let session = try await alfred.createSession()
                widgetData = session.widgetData
                if let id = session.orchestrationSessionId { alfredSessionId = id }
                initCheckout()
                if sessionError == nil { checkoutStep = .pay }
            } catch {
                sessionError = "\(error.localizedDescription)\n\nIs alfred running? \(alfredBaseURL)"
            }
            creatingSession = false
        }
    }

    func backToCart() {
        guard !submitting else { return }
        checkoutStep = .cart
    }

    /// Ask the **session**, through alfred, whether the money moved — the same read a merchant's
    /// backend makes. Polls while it is pending, like `awaitPaymentOutcome()`.
    func confirmPayment() {
        guard !confirming, !alfredSessionId.isEmpty else { return }
        confirming = true
        Task {
            do {
                let deadline = ContinuousClock.now + .seconds(20)
                var status = try await sessionStatus()
                while case .pending = status, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .seconds(2))
                    status = try await sessionStatus()
                }
                confirmedStatus = status
            } catch {
                // A confirmation that cannot be fetched is not a failed payment: leave the screen
                // on whatever the attempt itself reported.
                snackbar = "Couldn't reach the payment session: \(error.asPurseError().message)"
            }
            confirming = false
        }
    }

    private func sessionStatus() async throws -> PaymentSessionStatus {
        let rows = try await alfred.paymentSession(id: alfredSessionId)
        let data = try JSONSerialization.data(withJSONObject: rows.map(\.rawObject))
        return PaymentSessionStatus.from(try JSONDecoder().decode([JSONValue].self, from: data))
    }

    func backToShop() {
        startOver()
        confirmedStatus = nil
        orderReference = Self.newOrderReference()
        checkoutStep = .cart
    }

    private static func newOrderReference() -> String {
        "PRS-\(Int.random(in: 100_000...999_999))"
    }

    // MARK: Screen 2

    var expressMethods: [PaymentItem] {
        (checkout?.paymentMethods ?? []).filter(Self.isExpress)
    }

    var payableMethods: [PaymentItem] {
        (checkout?.paymentMethods ?? []).filter { item in
            guard case .primaryMethod = item else { return false }
            return !Self.isExpress(item)
        }
    }

    var giftCardMethods: [SecondaryMethod] { checkout?.secondaryMethods ?? [] }

    /// Everything a row can select. **`checkout.paymentMethods` excludes saved cards** — they live
    /// on `paymentTokens` — so that list alone silently misses every token.
    var selectableItems: [PaymentItem] {
        guard let checkout else { return [] }
        return checkout.paymentMethods + checkout.paymentTokens.map(PaymentItem.paymentToken)
    }

    var selectedItem: PaymentItem? {
        selectableItems.first { $0.id == selectedItemId }
    }

    /// Nothing selected means the gift-cards-only path, which needs the order fully covered.
    var canPay: Bool {
        guard let checkout else { return false }
        guard let item = selectedItem else { return checkout.isPaymentFulfilled }
        let element = element(for: item)
        return element.hasUI ? element.isReady : true
    }

    /// These render their own branded button. Apple Pay takes Google Pay's slot in Android's
    /// Express section.
    private static func isExpress(_ item: PaymentItem) -> Bool {
        item.method == .applePay || (item.partner == .paypal && item.method == .wallet)
    }

    func label(_ item: PaymentItem) -> String {
        switch item {
        case let .paymentToken(token):
            // A vaulted card can arrive with no name and no masked PAN.
            return token.name.nonEmpty ?? token.maskedPAN.nonEmpty ?? token.brand.nonEmpty
                ?? token.id.nonEmpty ?? "Saved card"
        default:
            return "\(item.partner.wireValue) · \(item.method.wireValue)"
        }
    }

    /// The CDN badge for a row. Checkout mode shows it; the playground deliberately does not.
    func iconURL(for item: PaymentItem) -> String {
        checkout?.iconURL(for: item) ?? ""
    }

    /// A name a shopper recognises; `label(_:)` is developer-facing and prints raw wire values.
    func shopperLabel(_ item: PaymentItem) -> String {
        switch item {
        case let .paymentToken(token):
            let brand = Self.brandName(token.brand)
            guard let pan = token.maskedPAN.nonEmpty else { return brand }
            return "\(brand) \(pan.suffix(4))"
        case let .primaryMethod(method):
            return Self.methodName(method.method)
        case let .secondaryMethod(method):
            return Self.methodName(method.method)
        default:
            return label(item)
        }
    }

    /// Keyed off the **method**, not the partner, as `usp-widget`'s `translation.method` block does
    /// — a shopper picks how to pay, not which acquirer routes it. Only a wallet keeps a brand.
    private static func methodName(_ method: PaymentMethod) -> String {
        switch method {
        case .creditCard: return "Bank card"
        case .applePay: return "Apple Pay"
        case .wallet: return "PayPal"
        case .installments: return "Pay in instalments"
        case .bnpl: return "Pay later"
        case .giftCard: return "Gift card"
        case let .other(wire):
            // usp-widget's own table, for the wire values this SDK has no case for.
            switch wire.uppercased() {
            case "GOOGLEPAY": return "Google Pay"
            case "PAYPAL": return "PayPal"
            case "VOUCHER": return "Voucher"
            case "INVOICE": return "Invoice payment"
            case "SEPA", "SEPASINGLE": return "SEPA direct debit"
            case "SEPAINSTANT": return "Instant SEPA direct debit"
            case "SEPARECURRENT": return "Recurring SEPA direct debit"
            case "IDEAL": return "iDeal"
            case "MBWAY": return "MB Way"
            case "MULTIBANCO": return "Multibanco"
            case "BANCONTACT": return "Bank card (Bancontact)"
            case "BIZUM": return "Bizum"
            case "TWINT": return "Twint"
            case "INSTANTPAYMENT": return "Instant payment"
            case "LOAN": return "Deferred payment"
            case "PAYLATER": return "Pay in 30 days by bank card"
            case "REVOLVING": return "Revolving credit payment"
            case "COMPTANT": return "Pay in full"
            case "LOYALTYCARD": return "Loyalty card"
            case "CONNECT": return "Connect"
            // An unknown method is still a method, not a partner: show the wire value.
            default: return wire.capitalized
            }
        @unknown default:
            return method.wireValue.capitalized
        }
    }

    /// Wire values arrive shouting (`VISA`, `PAYPAL`); a brand is a proper noun.
    private static func brandName(_ wire: String) -> String {
        switch wire.uppercased() {
        case "": return "Card"
        case "VISA": return "Visa"
        case "MASTERCARD": return "Mastercard"
        case "AMERICAN_EXPRESS", "AMEX": return "American Express"
        case "CARTE_BANCAIRE", "CB": return "Cartes Bancaires"
        case "MAESTRO": return "Maestro"
        case "PAYPAL": return "PayPal"
        case "DINERS_CLUB": return "Diners Club"
        case "DISCOVER": return "Discover"
        case "UNIONPAY": return "UnionPay"
        case "JCB": return "JCB"
        case "ONEY": return "Oney"
        default: return wire.capitalized
        }
    }

    func shopperDetail(_ item: PaymentItem) -> String? {
        switch item {
        case let .paymentToken(token):
            return token.requiresCVV ? "Security code required" : "Ready to pay"
        case let .primaryMethod(method):
            if method.disabled != nil { return "Not available for this order" }
            if method.configuration.template == "redirection" { return "Continue on the provider's page" }
            return nil
        default:
            return nil
        }
    }

    func subtitle(_ item: PaymentItem) -> String {
        switch item {
        case let .paymentToken(token):
            let bits = [token.maskedPAN, token.brand, token.requiresCVV ? "CVC required" : "no CVC"]
            return bits.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case let .primaryMethod(method):
            if let disabled = method.disabled { return "unavailable — \(disabled.code.rawValue)" }
            return method.configuration.template ?? method.method.wireValue
        default:
            return item.id
        }
    }

    /// Selecting is what creates the element, and building one runs the partner's `prepare` — a
    /// `POST /init` for Klarna and Apple Pay. Nothing is prepared for an unselected row.
    func select(_ item: PaymentItem?) {
        guard let checkout else { return }
        guard let item, item.id != selectedItemId else {
            selectedItemId = nil
            checkout.clearPrimarySplit()
            return
        }
        selectedItemId = item.id
        do {
            switch item {
            case let .primaryMethod(method): try checkout.setPrimary(method)
            case let .paymentToken(token): try checkout.setPrimaryToken(token)
            default: return
            }
        } catch {
            snackbar = "\(error)"
            selectedItemId = nil
            return
        }
        _ = element(for: item)
    }

    /// Built once and kept, keyed on the item's generation — `setSession` bumps that for a method
    /// whose configuration changed.
    func element(for item: PaymentItem) -> PaymentElement {
        let key = "\(item.id):\(checkout?.itemGenerations[item.id] ?? 0)"
        if let existing = elements[key] { return existing }

        let spy = ElementSpy(controller: self, item: item)
        let element = checkout!.paymentElement(
            for: item,
            listener: spy,
            redirect: presenter,
            appReturnURL: URL(string: "com.purse.headlesscheckout.demo.klarna://return")
        )
        listeners[key] = spy
        elements[key] = element
        // `isReady` is published on the element, not here: without this the Pay button never
        // re-renders when the card form becomes valid.
        element.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        Task { await element.prepare() }
        return element
    }

    func submit() {
        guard let item = selectedItem else {
            submitSecondariesOnly()
            return
        }
        submitting = true
        Task {
            await element(for: item).submit().value
            submitting = false
        }
    }

    /// Gift cards covering the whole order: no primary to drive, so submit the checkout directly.
    private func submitSecondariesOnly() {
        guard let checkout, checkout.isPaymentFulfilled else {
            snackbar = "Pick a payment method first"
            return
        }
        submitting = true
        Task {
            do {
                let validation = try await checkout.submitPayment()
                finish(.completed(validation), method: "gift cards")
            } catch {
                finish(.failed(error.asPurseError()), method: "gift cards")
            }
            submitting = false
        }
    }

    // MARK: Gift cards

    struct GiftCardState {
        var pan = ""
        var cvv = ""
        var amount = ""
        var keep = false
        var name = ""
        var checking = false
        var error: String?
        var token: SecondaryToken?
        var applied: Decimal?
    }

    func giftCard(_ method: SecondaryMethod) -> GiftCardState {
        giftCards[method.id] ?? GiftCardState()
    }

    func updateGiftCard(_ method: SecondaryMethod, _ mutate: (inout GiftCardState) -> Void) {
        var state = giftCard(method)
        mutate(&state)
        giftCards[method.id] = state
    }

    func requiresCVV(_ method: SecondaryMethod, pan: String) -> Bool {
        checkout?.secondaryConfig(for: method)?.requiresCVV(pan: pan) ?? false
    }

    func checkBalance(_ method: SecondaryMethod) {
        guard let checkout else { return }
        let state = giftCard(method)
        updateGiftCard(method) { $0.checking = true; $0.error = nil }
        Task {
            do {
                let token = try await checkout.getSecondaryToken(
                    method: method,
                    pan: state.pan,
                    cvv: state.cvv.isEmpty ? nil : state.cvv
                )
                updateGiftCard(method) { $0.token = token; $0.checking = false }
                log("\(method.id) → balance \(amountText(token.balance, checkout.currency))")
            } catch {
                updateGiftCard(method) { $0.error = "\(error)"; $0.checking = false }
            }
        }
    }

    func applyGiftCard(_ method: SecondaryMethod) {
        guard let checkout, let token = giftCard(method).token else { return }
        let state = giftCard(method)
        do {
            if state.keep || !state.name.isEmpty {
                try checkout.registerSecondary(token, registered: state.keep, name: state.name.nonEmpty)
            }
            let requested = state.amount.nonEmpty.flatMap { Decimal(string: $0) }
            try checkout.applySecondary(token, amount: requested)
            updateGiftCard(method) { $0.applied = requested ?? token.balance; $0.error = nil }
            log("\(method.id) → applied, left to pay \(amountText(checkout.remainingAmountToPay, checkout.currency))")
        } catch {
            updateGiftCard(method) { $0.error = "\(error)" }
        }
    }

    func removeGiftCard(_ method: SecondaryMethod) {
        guard let checkout, let token = giftCard(method).token else { return }
        checkout.removeSecondary(token)
        updateGiftCard(method) { $0.applied = nil }
    }

    func useSaved(_ token: SavedSecondaryToken) {
        guard let checkout else { return }
        do {
            try checkout.applySecondary(token)
            log("\(token.id) → applied from saved")
        } catch {
            snackbar = "\(error)"
        }
    }

    func removeSaved(_ token: SavedSecondaryToken) {
        checkout?.removeSecondary(token)
    }

    // MARK: Session refresh

    func refreshSession() {
        guard let checkout else { return }
        refreshingSession = true
        Task {
            do {
                let session = try await alfred.createSession()
                try checkout.setSession(session.widgetData)
                widgetData = session.widgetData
                elements.removeAll()
                listeners.removeAll()
                selectedItemId = nil
                sessionDetails = Self.summarize(checkout)
                log("session refreshed → \(checkout.currentSessionId) (\(amountText(checkout.session.amount, checkout.currency)))")
            } catch {
                snackbar = "\(error)"
            }
            refreshingSession = false
        }
    }

    // MARK: Screen 3

    func getTransactions() {
        loadingTransactions = true
        Task {
            do {
                let found = try await alfred.paymentSession(id: alfredSessionId)
                transactions = found
                rawTransactions = DemoJSON(raw: found.map(\.raw)).pretty
                if let result { self.result = result.confirmed(by: found) }
            } catch {
                rawTransactions = "\(error.localizedDescription)"
            }
            loadingTransactions = false
        }
    }

    func capture() {
        capturing = true
        Task {
            do {
                let minor = NSDecimalNumber(decimal: (Decimal(string: captureAmount) ?? 0) * 100).intValue
                captureRaw = try await alfred.capture(paymentId: capturePaymentId, amountMinorUnits: minor).pretty
            } catch {
                captureRaw = "\(error.localizedDescription)"
            }
            capturing = false
        }
    }

    func startOver() {
        teardownCheckout()
        checkout = nil
        result = nil
        transactions = []
        rawTransactions = ""
        captureRaw = ""
        selectedItemId = nil
        giftCards.removeAll()
        widgetData = ""
        step = .session
    }

    func back() {
        guard !submitting else { return }
        switch step {
        case .session: exitMode()
        case .pay: step = .session
        case .result: step = .pay
        }
    }

    /// Back to the picker, tearing the session down so the other mode starts clean.
    func exitMode() {
        guard !submitting else { return }
        startOver()
        confirmedStatus = nil
        checkoutStep = .cart
        mode = nil
    }

    // MARK: Element callbacks

    func log(_ line: String) { events.append(line) }

    /// A setup failure (an express method whose `prepare` could not `/init`) is reported where the
    /// shopper already is. Anything else is a payment outcome, even from a self-submitting button
    /// (PayPal, Apple Pay) that never sets `submitting`.
    func finish(_ outcome: PaymentOutcome, method: String) {
        if !submitting, case let .failed(error) = outcome {
            snackbar = "\(method): \(error.message)"
            return
        }
        guard let result = DemoResult.from(outcome, method: method) else {
            snackbar = "Payment canceled"
            return
        }
        self.result = result
        step = .result
        // Checkout mode's own last screen, which resolves the outcome through the SDK, not alfred.
        checkoutStep = .confirmation
    }

    /// Android never tears down on Activity destroy; this does, which is what the SDK asks for.
    func teardownCheckout() {
        checkout?.teardown()
        cancellables.removeAll()
        elements.removeAll()
        listeners.removeAll()
    }

    // MARK: Helpers

    private static func resolveAlfredSessionId(widgetData: String) -> String? {
        guard let data = Data(base64Encoded: widgetData),
              let blob = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let legacy = blob["legacy_payment_session_id"] as? String, !legacy.isEmpty { return legacy }
        return (blob["payment_session"] as? [String: Any])?["id"] as? String
    }

    private static func summarize(_ checkout: PurseHeadlessCheckout) -> String {
        var lines: [String] = [
            "session      \(checkout.currentSessionId)",
            "amount       \(amountText(checkout.session.amount, checkout.currency))",
            "info request \(checkout.isInformationRequest)",
            "state        \(checkout.sessionState.rawValue)",
            "rest to pay  \(amountText(checkout.remainingAmountToPay, checkout.currency))",
            "fulfilled    \(checkout.isPaymentFulfilled)",
            "api root     \(checkout.paymentAPIRoot)",
            "",
            "methods",
        ]
        for item in checkout.paymentMethods {
            let disabled = item.disabled.map { " [disabled: \($0.code.rawValue)]" } ?? ""
            lines.append("  \(item.id) template=\(item.configuration.template ?? "-")\(disabled)")
        }
        if !checkout.paymentTokens.isEmpty {
            lines.append("")
            lines.append("saved cards")
            for token in checkout.paymentTokens {
                lines.append("  \(token.id) \(token.maskedPAN ?? "") cvv=\(token.requiresCVV)\(token.favorite ? " ★" : "")")
            }
        }
        if !checkout.amountSplit.isEmpty {
            lines.append("")
            lines.append("split")
            for split in checkout.amountSplit {
                lines.append("  \(amountText(split.amount, checkout.currency))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// One per element. Bridges the SDK's listener onto the controller.
@MainActor
final class ElementSpy: PaymentElementListener {
    private unowned let controller: DemoController
    private let item: PaymentItem

    init(controller: DemoController, item: PaymentItem) {
        self.controller = controller
        self.item = item
    }

    func onReady(_ ready: Bool) {
        controller.log("\(item.id) → ready=\(ready)")
    }

    func onRequiresAction() {
        controller.snackbar = "Redirecting for authentication…"
        controller.log("\(item.id) → redirect required")
    }

    func onPaymentId(_ paymentId: String) {
        controller.capturePaymentId = paymentId
        controller.log("\(item.id) → payment_id=\(paymentId)")
    }

    func onOutcome(_ outcome: PaymentOutcome) {
        controller.log("\(item.id) → \(outcome)")
        // The transactions lookup wants the **payment** session, which `/validate` names in
        // `results[].session_id`.
        if case let .completed(result) = outcome,
           let sessionId = result.raw["results"]?.arrayValue?
               .compactMap({ $0["session_id"]?.stringValue }).first(where: { !$0.isEmpty }) {
            controller.alfredSessionId = sessionId
            controller.log("\(item.id) → payment session=\(sessionId)")
        }
        // A redirect return carries the payment id in its token; `onPaymentId` only fires when
        // `/validate` itself named one.
        if case let .returnedFromRedirect(url) = outcome,
           let paymentId = url?.absoluteString.widgetRedirectionData?.paymentId {
            controller.capturePaymentId = paymentId
        }
        controller.finish(outcome, method: controller.label(item))
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
