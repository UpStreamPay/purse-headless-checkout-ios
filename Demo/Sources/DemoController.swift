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

    /// `nil` until a mode is picked. The playground is the SDK workbench; checkout is the
    /// shopper-facing flow. Both drive this one controller — a second would be a second copy of the
    /// session-minting path.
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

    /// What the session's own transactions say, via the SDK's `awaitPaymentOutcome()`. `nil` until
    /// asked. The playground's alfred lookup is deliberately not used here.
    @Published var confirmedStatus: PaymentSessionStatus?
    @Published var confirming = false
    /// A stable order number for the confirmation page, minted per checkout run.
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

    /// One presenter for every redirect, returning to the page `AlfredClient` puts on the order.
    /// `prefersInAppWebView` because this demo claims no Associated Domain for `cdn.purse-dev.com`
    /// — nobody's demo app could.
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
        // No `ServiceLoader` on this platform: each partner product is installed explicitly.
        // Apple Pay's merchant id is entitlement-bound, so it can only come from the app.
        PluginRegistry.shared.install(ApplePayModule(configuration: ApplePayConfiguration(
            merchantIdentifier: "merchant.eu.purse.demo",
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
            // The screens read `@Published` state off the checkout; SwiftUI only observes the
            // object it was handed, so the change has to be forwarded.
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

    /// The basket's Checkout button. Mints a session if there is not already one, then moves to the
    /// payment page — the shopper never sees that alfred was involved.
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

    /// Ask the **session** whether the money moved — the call a merchant actually has. The
    /// playground answers the same question through alfred, which no merchant can do.
    func confirmPayment() {
        guard let checkout, !confirming else { return }
        confirming = true
        Task {
            do {
                confirmedStatus = try await checkout.awaitPaymentOutcome(
                    timeout: .seconds(20), pollInterval: .seconds(2)
                )
            } catch {
                // A confirmation that cannot be fetched is not a failed payment, so the screen keeps
                // whatever the attempt itself reported rather than inventing a verdict.
                snackbar = "Couldn't reach the payment session: \(error.localizedDescription)"
            }
            confirming = false
        }
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

    /// Everything a row can select. **`checkout.paymentMethods` deliberately excludes saved cards**
    /// — they live on `paymentTokens` — so looking a selection up in that list alone silently misses
    /// every token.
    var selectableItems: [PaymentItem] {
        guard let checkout else { return [] }
        return checkout.paymentMethods + checkout.paymentTokens.map(PaymentItem.paymentToken)
    }

    var selectedItem: PaymentItem? {
        selectableItems.first { $0.id == selectedItemId }
    }

    /// What the Pay button gates on. With nothing selected it is the gift-cards-only path, which
    /// needs the order fully covered.
    var canPay: Bool {
        guard let checkout else { return false }
        guard let item = selectedItem else { return checkout.isPaymentFulfilled }
        let element = element(for: item)
        return element.hasUI ? element.isReady : true
    }

    /// Apple Pay and PayPal render their own branded button and pay from its tap. Google Pay has no
    /// iOS peer; Apple Pay takes its slot in Android's Express checkout section.
    private static func isExpress(_ item: PaymentItem) -> Bool {
        item.method == .applePay || (item.partner == .paypal && item.method == .wallet)
    }

    func label(_ item: PaymentItem) -> String {
        switch item {
        case let .paymentToken(token):
            // A vaulted card can arrive with no name and no masked PAN; the row must still say
            // something.
            return token.name.nonEmpty ?? token.maskedPAN.nonEmpty ?? token.brand.nonEmpty
                ?? token.id.nonEmpty ?? "Saved card"
        default:
            return "\(item.partner.wireValue) · \(item.method.wireValue)"
        }
    }

    /// The CDN badge for a row, straight from the SDK. Checkout mode's rows show it; the playground
    /// deliberately does not, so the two modes differ in chrome and not in capability.
    func iconURL(for item: PaymentItem) -> String {
        checkout?.iconURL(for: item) ?? ""
    }

    /// A name a shopper recognises. `label(_:)` is the developer-facing one and prints raw wire
    /// values, which is right in the playground and wrong on a payment page.
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

    /// Keyed off the **method**, not the partner — the same way `usp-widget` does it (its
    /// `translation.method` block: `CREDITCARD` → "Bank card", `INSTALLMENTS` → "Pay in
    /// instalments"). A shopper picks how they want to pay, not which acquirer routes it: "Redsys"
    /// and "Ingenico" are names they have never seen, and two rows both reading "Card" is a better
    /// problem than one row reading "Worldline".
    ///
    /// Only a wallet keeps a brand, because there the brand *is* the method.
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
            // An unknown method is still a payment method, not a partner: show the wire value
            // rather than inventing a brand.
            default: return wire.capitalized
            }
        }
    }

    /// Wire values arrive shouting (`VISA`, `PAYPAL`). A brand is a proper noun, so it keeps its own
    /// capitalisation — but never the wire's.
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

    /// One line under the name, or nothing. A shopper needs to know a security code is coming, not
    /// which template the method uses.
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

    /// Selecting is what creates the element: building one runs the partner's `prepare`, which for
    /// Klarna and redirection methods is a `POST /init`. Nothing is prepared for an unselected row.
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

    /// The element for `item`, built once and kept. Keyed on the item's generation, which
    /// `setSession` bumps for a method whose configuration changed.
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
        // `isReady` is published on the element, not on this controller, so without this the Pay
        // button never re-renders when the card form becomes valid.
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

    /// Gift cards covering the whole order: there is no primary to drive, so the checkout is
    /// submitted directly.
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
        // The first screen's back goes up a level, to the mode picker.
        case .session: exitMode()
        case .pay: step = .session
        case .result: step = .pay
        }
    }

    /// Leave the current mode and return to the picker, tearing the session down on the way out so
    /// the other mode starts clean.
    func exitMode() {
        guard !submitting else { return }
        startOver()
        confirmedStatus = nil
        checkoutStep = .cart
        mode = nil
    }

    // MARK: Element callbacks

    func log(_ line: String) { events.append(line) }

    /// Only a payment that was actually in flight reaches the result screen. A setup failure — an
    /// express method whose `prepare` could not `/init`, say — is reported where the shopper is and
    /// leaves them free to pick something else.
    func finish(_ outcome: PaymentOutcome, method: String) {
        guard submitting else {
            if case let .failed(error) = outcome { snackbar = "\(method): \(error.message)" }
            return
        }
        guard let result = DemoResult.from(outcome, method: method) else {
            snackbar = "Payment canceled"
            return
        }
        self.result = result
        step = .result
        // Checkout mode has its own last screen, which resolves the outcome through the SDK rather
        // than through alfred.
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
        // The transactions lookup wants the **payment** session, and the `/validate` answer names
        // it outright in `results[].session_id`.
        if case let .completed(result) = outcome,
           let sessionId = result.raw["results"]?.arrayValue?
               .compactMap({ $0["session_id"]?.stringValue }).first(where: { !$0.isEmpty }) {
            controller.alfredSessionId = sessionId
            controller.log("\(item.id) → payment session=\(sessionId)")
        }
        // A redirect return carries the payment id in its token, which the capture card wants and
        // which `onPaymentId` only fires for when `/validate` itself named one.
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
