// Web: packages/headless-checkout/src/headless-checkout.ts
// Same: session in force, method list, split, fulfilment, setSession survivor rules.
// Differs: @Published properties rather than Svelte stores / StateFlow. Submit, plugins, wallet operations, BNPL and teardown land in later PRs.

import Combine
import Foundation

/// The checkout for one Purse payment session. Create it from the base64 `widget.data` blob your
/// backend returns, observe its published state, and drive the split by selecting a primary method
/// and applying secondary instruments.
@MainActor
public final class PurseHeadlessCheckout: ObservableObject {

    // MARK: Session identity

    /// This checkout's id in Purse's monitoring. Stable across ``setSession(_:)``.
    public let instanceId: String

    /// Decoded `widget.data`. Replaced by ``setSession(_:)``.
    public private(set) var params: PurseSessionParams

    /// Methods this app build opts out of, whatever the session offers. Re-applied by ``setSession(_:)``.
    public let disabledMethods: Set<MethodKey>

    /// Resolved Payment API root; calls go to `{root}/{entityId}/sessions/{sessionId}/…`.
    ///
    /// Re-resolved by ``setSession(_:)``, since the new blob may name a different host.
    public private(set) var paymentAPIRoot: String

    public var currency: String { session.currency }
    public var isInformationRequest: Bool { session.isInformationRequest }
    public var currentSessionId: String { session.id }

    private let environment: PurseEnvironment
    /// Kept so ``setSession(_:)`` can re-apply the same trust decision to the incoming blob.
    private let lockedEnvironment: PurseEnvironment?

    // MARK: Published state

    /// The built session model. Hold the checkout, not this — it is replaced by ``setSession(_:)``.
    @Published public private(set) var session: PaymentSession

    @Published public private(set) var sessionState: SessionState = .ready

    /// Selectable means of payment: primary and secondary **methods** only. Saved instruments have
    /// their own properties (``paymentTokens``, ``savedSecondaryTokens``), and filtered-disabled
    /// items are excluded entirely — a merchant never renders those.
    @Published public private(set) var paymentMethods: [PaymentItem] = []

    /// Saved cards-on-file offered by the session.
    @Published public private(set) var paymentTokens: [PaymentToken] = []

    /// Saved gift cards / vouchers offered by the session.
    @Published public private(set) var savedSecondaryTokens: [SavedSecondaryToken] = []

    /// What a primary still has to pay, after applied secondaries.
    @Published public private(set) var remainingAmountToPay: Decimal = 0

    /// Whether the split covers the amount *and* every item in it reports its form complete.
    @Published public private(set) var isPaymentFulfilled = false

    /// The submittable set: each applied secondary's slice, plus the primary's remainder.
    @Published public private(set) var amountSplit: [PaymentSplit] = []

    /// Bumped per item id when a `setSession` invalidates it, so UI keyed on
    /// `(item.id, generation)` rebuilds exactly the elements whose configuration changed.
    @Published public private(set) var itemGenerations: [String: Int] = [:]

    // MARK: Internal model

    /// Every item, including the filtered-disabled ones the published list hides.
    private var meansOfPayment: [PaymentItem] = []
    private var splitter: PursePaymentSplitter
    /// Per-item form completeness, armed when an item needs one (a card form, a CVV re-entry).
    private var fulfilledByItem: [String: Bool] = [:]
    /// What each item's native step produced, threaded into its `/validate` payload.
    private var collectedByItem: [String: [String: JSONValue]] = [:]
    /// Set once a `/validate` has answered — a declined payment spends the session just as a
    /// successful one does, so a second submit must never reach the PSP.
    private var validationConsumed = false
    private let registry: PluginRegistry
    private let hooks: PurseCheckoutHooks?
    private let serverClock: ServerDatetimeChecker
    /// Injectable so tests can stub the transport — the seam `purse-ios-securefields` calls
    /// `testURLSession`. Production callers never pass it.
    private let urlSession: URLSession

    // MARK: Creation

    /// - Parameters: - widgetData: the base64 `widget.data` string from your backend's Client
    /// Session response. - lockedEnvironment: overrides whatever `widgetData` declares.
    public init(
        widgetData: String,
        lockedEnvironment: PurseEnvironment? = nil,
        disabledMethods: Set<MethodKey> = [],
        hooks: PurseCheckoutHooks? = nil,
        registry: PluginRegistry = .shared,
        instanceId: String = UUID().uuidString,
        urlSession: URLSession = .shared
    ) throws {
        let params = try SessionCodec.decode(widgetData)
        self.params = params
        let environment = lockedEnvironment ?? params.environment
        self.environment = environment
        self.lockedEnvironment = lockedEnvironment
        self.paymentAPIRoot = Self.resolveAPIRoot(params, locked: lockedEnvironment, environment: environment)
        self.disabledMethods = disabledMethods
        self.hooks = hooks
        self.registry = registry
        self.instanceId = instanceId
        self.urlSession = urlSession

        let datetimeAPI = DatetimeAPIClient(
            apiKey: params.apiKey,
            datetimeAPIRoot: environment.datetimeAPIRoot,
            session: urlSession
        )
        self.serverClock = ServerDatetimeChecker(fetchServerTime: { try await datetimeAPI.datetime() })

        let built = PaymentSessionBuilder.build(params.paymentSession, disabledMethods: disabledMethods)
        self.session = built
        self.meansOfPayment = built.meansOfPayment
        self.splitter = PursePaymentSplitter(orderAmount: built.amount)

        registry.install(RedirectionModule())
        refresh()
    }

    /// Where this session's Payment API calls go. A build-**locked** (release) environment trusts
    /// its own known root and ignores whatever `api_url` the session declares — that is the whole
    /// point of locking, and ``PurseEnvironment``'s own header says so.
    private static func resolveAPIRoot(
        _ params: PurseSessionParams,
        locked: PurseEnvironment?,
        environment: PurseEnvironment
    ) -> String {
        guard locked == nil, let declared = params.apiURL.nonBlank else { return environment.paymentAPIRoot }
        return declared
    }

    /// The Payment API client for the session in force.
    private var api: PaymentAPIClient {
        PaymentAPIClient(
            apiKey: params.apiKey,
            apiRoot: paymentAPIRoot,
            entityId: params.entityId,
            sessionId: session.id,
            session: urlSession
        )
    }

    // MARK: Submitting

    /// Build the payment: `preValidation` for every split, one `POST /validate`, then each plugin's
    /// `postValidation`.
    @discardableResult
    public func submitPayment(skipOnBeforeValidate: Bool = false) async throws -> ValidationResult {
        try acquireSubmitLock()

        guard splitter.fulfilled else {
            sessionState = .ready
            throw PurseCheckoutError.paymentNotFulfilled("the split does not cover the amount to pay")
        }
        if let itemId = unfulfilledItemId {
            sessionState = .ready
            throw PurseCheckoutError.itemNotFulfilled(itemId: itemId)
        }

        // Every selectable item is locked for the duration, then unlocked whatever happens.
        refresh()
        defer {
            sessionState = sessionState == .submitting ? .error : sessionState
            refresh()
        }

        let validator = PaymentValidator(api: api, registry: registry)
        let result: ValidationResult
        do {
            result = try await validator.execute(
                splits: splitter.splits,
                session: session.source,
                collectedByItem: collectedByItem,
                hooks: hooks,
                skipOnBeforeValidate: skipOnBeforeValidate
            )
        } catch {
            // The session is only spent once /validate actually answered. A hook that aborted, or a
            // transport failure, leaves it submittable — except when the outcome is unknown, where
            // the payment may exist and a retry could double-charge.
            if let checkoutError = error as? PurseCheckoutError,
               case let .validateFailed(_, underlying) = checkoutError,
               (underlying as? PaymentAPIError)?.outcomeUnknown == true {
                validationConsumed = true
                sessionState = .submitted
            } else {
                sessionState = .ready
            }
            throw error
        }

        validationConsumed = true
        sessionState = .submitted
        return result
    }

    /// The redirect the last `/validate` asked for, if any — a 3-D Secure challenge or a PSP page.
    /// Reaching the returned action's destination is **not** an outcome: the final redirect is
    /// built server-side and can land on a URL this client cannot read.
    public func pendingRedirect(for result: ValidationResult) -> RedirectAction? {
        let primary = splitter.primaryMethod
        return RedirectionResolver.resolve(
            validateResponse: result.raw,
            partner: primary?.partner.wireValue ?? "",
            method: primary?.method.wireValue ?? "",
            sessionReturnURL: session.source.redirection
        )?.withReturnURLPrefix(session.source.redirection)
    }

    /// Re-checks expiry against the server-corrected clock, then moves `ready`/`error` →
    /// `submitting`.
    private func acquireSubmitLock() throws {
        if validationConsumed {
            throw PurseCheckoutError.submitBlocked(state: .submitted)
        }
        guard sessionState == .ready || sessionState == .error else {
            throw PurseCheckoutError.submitBlocked(state: sessionState)
        }
        if session.expirationDate < Date() {
            sessionState = .expired
            throw PurseCheckoutError.sessionExpired(sessionId: session.id)
        }
        sessionState = .submitting
    }

    /// Stash what an item's native step produced, for its next `/validate` payload.
    public func setCollected(_ itemId: String, _ data: [String: JSONValue]) {
        collectedByItem[itemId] = data
    }

    /// Synchronise the expiry clock with the server. Failures are swallowed — a payment must never
    /// be blocked because a clock-sync call timed out.
    public func syncServerClock() async {
        await serverClock.sync()
    }

    // MARK: Selecting the primary

    /// Choose the method that pays whatever the secondaries do not cover.
    public func setPrimary(_ method: PrimaryMethod?) throws {
        guard let method else {
            splitter.setPrimary(nil)
            refresh()
            return
        }
        try selectPrimary(method, itemId: method.id)
    }

    /// Pay with a saved card. When the token ``PaymentToken/requiresCVV``, the fulfilment gate is
    /// armed: the checkout is not fulfilled until the CVV form reports valid.
    public func setPrimaryToken(_ token: PaymentToken) throws {
        try selectPrimary(token, itemId: token.id)
        if token.requiresCVV, fulfilledByItem[token.id] == nil {
            fulfilledByItem[token.id] = false
            refresh()
        }
    }

    private func selectPrimary(_ source: any PrimarySource, itemId: String) throws {
        if let disabled = currentItem(id: itemId)?.disabled {
            throw PurseCheckoutError.methodDisabled(itemId: itemId, disabled: disabled)
        }
        splitter.setPrimary(source)
        refresh()
    }

    /// Drop the primary, leaving only whatever secondaries cover.
    public func clearPrimarySplit() {
        splitter.setPrimary(nil)
        refresh()
    }

    // MARK: Secondaries

    /// Draw a tokenized secondary instrument into the split. See
    /// ``PursePaymentSplitter/takeSplit(_:requestedAmount:)`` for the refusal rules.
    public func applySecondary(_ token: SecondaryToken, amount: Decimal? = nil) throws {
        try splitter.takeSplit(token, requestedAmount: amount)
        refresh()
    }

    /// Draw a saved gift card into the split.
    public func applySecondary(_ token: SavedSecondaryToken, amount: Decimal? = nil) throws {
        try applySecondary(token.asSecondaryToken(), amount: amount)
    }

    public func removeSecondary(_ token: SecondaryToken) {
        splitter.clearSplit(token)
        refresh()
    }

    public func removeSecondary(_ token: SavedSecondaryToken) {
        removeSecondary(token.asSecondaryToken())
    }

    /// The applied secondary instruments, in the order they were added.
    public var appliedSecondaries: [SecondaryToken] { splitter.appliedSecondaries }

    // MARK: Fulfilment

    /// Report whether an item's own form is complete.
    public func setFulfilled(_ itemId: String, _ fulfilled: Bool) {
        fulfilledByItem[itemId] = fulfilled
        refresh()
    }

    /// The id of an item in the split that still reports its form incomplete, if any.
    public var unfulfilledItemId: String? {
        splitter.splits.map(\.source.id).first { fulfilledByItem[$0] == false }
    }

    // MARK: Session refresh

    /// Hand the checkout a **new** Client Session without tearing the screen down — the cart
    /// changed, or the previous session expired and your backend minted a fresh one.
    public func setSession(_ widgetData: String) throws {
        let newParams = try SessionCodec.decode(widgetData)
        let incoming = newParams.paymentSession

        if incoming.expirationDate < Date() {
            throw PurseCheckoutError.sessionExpired(sessionId: incoming.id)
        }
        // Same session id → ignored with no change, as on web.
        if incoming.id == session.id { return }

        let previousItems = Dictionary(
            meansOfPayment.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let previousPrimaryId = splitter.primaryMethod?.id

        let built = PaymentSessionBuilder.build(incoming, disabledMethods: disabledMethods)
        // The new blob may name a different host; the locked-environment decision is re-applied to
        // it unchanged.
        paymentAPIRoot = Self.resolveAPIRoot(newParams, locked: lockedEnvironment, environment: environment)

        // An item survives only when its configuration is deep-equal; anything else is a different
        // method wearing the same id.
        var survivingIds: Set<String> = []
        for item in built.meansOfPayment {
            if let previous = previousItems[item.id], previous.configuration == item.configuration {
                survivingIds.insert(item.id)
            } else if previousItems[item.id] != nil {
                itemGenerations[item.id, default: 0] += 1
            }
        }
        for (id, _) in previousItems where built.meansOfPayment.allSatisfy({ $0.id != id }) {
            itemGenerations[id, default: 0] += 1
        }

        params = newParams
        session = built
        meansOfPayment = built.meansOfPayment
        fulfilledByItem = fulfilledByItem.filter { survivingIds.contains($0.key) }

        // Gift cards were tokenized against the old session and cannot carry over.
        splitter.reset(orderAmount: built.amount)
        if let previousPrimaryId, survivingIds.contains(previousPrimaryId) {
            restorePrimary(id: previousPrimaryId)
        }

        collectedByItem.removeAll()
        validationConsumed = false
        sessionState = .ready
        refresh()
    }

    private func restorePrimary(id: String) {
        switch meansOfPayment.first(where: { $0.id == id }) {
        case let .primaryMethod(method):
            splitter.setPrimary(method)
        case let .paymentToken(token):
            splitter.setPrimary(token)
        default:
            break
        }
    }

    // MARK: Recompute

    private func currentItem(id: String) -> PaymentItem? {
        meansOfPayment.first { $0.id == id }
    }

    /// Re-evaluate availability against the split and republish everything derived from it. Called
    /// after every change to the split or to an item's state — the analogue of web re-running
    /// `updateMopDisabledState` whenever `primaryReach` changes.
    private func refresh() {
        meansOfPayment = MethodAvailability.recompute(
            meansOfPayment,
            isInformationRequest: session.isInformationRequest,
            primaryReach: splitter.primaryReach,
            splitSources: splitter.splits.map(\.source)
        )

        // Filtered states mean "never show this" — the item stays in the internal list so a later
        // recompute can still see it, but no merchant ever renders it.
        var visible = meansOfPayment.filter { $0.disabled?.isFiltered != true }

        // `submitting` is a published overlay only, never written into the internal list: it must
        // lift cleanly when the submit ends, without erasing a real disabled state underneath.
        if sessionState == .submitting {
            visible = visible.map { $0.disabled == nil ? $0.withDisabled(.submitting) : $0 }
        }

        paymentMethods = visible.filter {
            switch $0 {
            case .primaryMethod, .secondaryMethod: true
            case .paymentToken, .savedSecondaryToken: false
            }
        }
        paymentTokens = visible.compactMap {
            if case let .paymentToken(token) = $0 { return token }
            return nil
        }
        savedSecondaryTokens = visible.compactMap {
            if case let .savedSecondaryToken(token) = $0 { return token }
            return nil
        }

        remainingAmountToPay = splitter.primaryReach
        amountSplit = splitter.splits
        isPaymentFulfilled = splitter.fulfilled && unfulfilledItemId == nil
    }
}
