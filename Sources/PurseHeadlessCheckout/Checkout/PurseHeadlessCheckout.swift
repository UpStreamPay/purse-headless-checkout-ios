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
    /// The override actually passed at creation, if any — kept separately from the resolved
    /// ``environment`` because two things need the *decision*, not its result: ``setSession(_:)``
    /// re-applies the same trust rule to the incoming blob's `api_url`, and ``saveState()`` hands
    private let lockedEnvironment: PurseEnvironment?
    /// The `widget.data` string decoded at creation — kept only so ``saveState()`` can round-trip
    /// the exact session ``restore(_:hooks:registry:secondaryConfigs:urlSession:)`` rebuilds from.
    private var widgetData: String

    // MARK: Published state

    /// The built session model. Hold the checkout, not this — it is replaced by ``setSession(_:)``.
    @Published public private(set) var session: PaymentSession

    @Published public private(set) var sessionState: SessionState = .ready

    /// `true` once ``teardown()`` ran. Every further operation that touches the network or mutates
    /// the session throws ``PurseCheckoutError/checkoutTornDown``.
    @Published public private(set) var isTornDown = false

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
    private let configs: SecondaryConfigs
    private let hooks: PurseCheckoutHooks?
    private let serverClock: ServerDatetimeChecker
    /// Web's `WATCHDOG_DURATION`, and Android's `WATCHDOG_INTERVAL_MS`.
    static let watchdogIntervalNanoseconds: UInt64 = 5_000_000_000
    /// Test seams: the background work started at creation, so a test can await the clock sync
    /// instead of racing it, and cancel the watchdog rather than leaving a timer running.
    var pendingClockSync: Task<Void, Never>?
    var expiryWatchdog: Task<Void, Never>?
    /// Injectable so tests can stub the transport — the seam `purse-ios-securefields` calls
    /// `testURLSession`. Production callers never pass it.
    private let urlSession: URLSession
    private let wallet: WalletTokens
    /// Save-token decisions for a fresh primary method, keyed by item id.
    private var registrationByMethod: [String: RegistrationState] = [:]
    /// Save-token decisions for a temporary secondary instrument, keyed by item id.
    private var registrationBySecondaryToken: [String: RegistrationState] = [:]

    // MARK: Creation

    /// - Parameters: - widgetData: the base64 `widget.data` string from your backend's Client
    /// Session response. - lockedEnvironment: overrides whatever `widgetData` declares.
    public init(
        widgetData: String,
        lockedEnvironment: PurseEnvironment? = nil,
        disabledMethods: Set<MethodKey> = [],
        hooks: PurseCheckoutHooks? = nil,
        registry: PluginRegistry = .shared,
        secondaryConfigs: SecondaryConfigs = .shared,
        instanceId: String = UUID().uuidString,
        urlSession: URLSession = .shared,
        walletAPIRootOverride: String? = nil
    ) throws {
        let params = try SessionCodec.decode(widgetData)
        self.params = params
        self.widgetData = widgetData
        self.lockedEnvironment = lockedEnvironment
        let environment = lockedEnvironment ?? params.environment
        self.environment = environment
        self.paymentAPIRoot = Self.resolveAPIRoot(params, locked: lockedEnvironment, environment: environment)
        self.disabledMethods = disabledMethods
        self.hooks = hooks
        self.registry = registry
        self.configs = secondaryConfigs
        self.instanceId = instanceId
        self.urlSession = urlSession

        let datetimeAPI = DatetimeAPIClient(
            apiKey: params.apiKey,
            datetimeAPIRoot: environment.datetimeAPIRoot,
            session: urlSession
        )
        self.serverClock = ServerDatetimeChecker(fetchServerTime: { try await datetimeAPI.datetime() })

        let built = PaymentSessionBuilder.build(
            params.paymentSession,
            disabledMethods: disabledMethods,
            configs: secondaryConfigs
        )
        self.session = built
        self.meansOfPayment = built.meansOfPayment
        self.splitter = PursePaymentSplitter(orderAmount: built.amount)
        self.wallet = WalletTokens(
            params: params,
            walletAPIRoot: walletAPIRootOverride ?? environment.walletAPIRoot,
            urlSession: urlSession
        )

        refresh()
        // Saved gift cards carry no balance in the session — re-`/init` each one now (web's
        // `buildSecondaryPaymentToken` fires the same call as the token is built).
        resolveSavedSecondaryBalances()
        // Only when the widget data actually carried a wallet_session — a checkout with none never
        // calls the Wallet API at all. A failure is swallowed: the wallet only gates management
        // operations and syncs names/favorites, so it must never break the checkout.
        if wallet.client != nil {
            pendingWalletSync = Task {
                _ = try? await self.wallet.fetch()
                self.syncWalletTokens()
            }
        }

        // Nothing else ever called `sync()`, so the offset stayed 0 and every "server-corrected"
        // check was really the device clock. One sync at creation is what makes the correction real.
        pendingClockSync = Task { [serverClock] in await serverClock.sync() }
        startExpiryWatchdog()
    }

    /// Move the session to ``SessionState/expired`` when its expiry passes *while the shopper is
    /// looking at the screen* — web's `ServerDatetimeChecker.WATCHDOG_DURATION`, Android's
    /// `startExpiryWatchdog`.
    private func startExpiryWatchdog() {
        expiryWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.watchdogIntervalNanoseconds)
                guard let self else { return }
                guard sessionState == .ready else { continue }
                if await serverClock.isExpiredForServer(session.expirationDate) {
                    sessionState = .expired
                }
            }
        }
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

    /// The Payment API client for the session in force. Every network path goes through here, so
    /// one guard covers them all — web's `apiClient()`.
    private var api: PaymentAPIClient {
        get throws {
            try requireOpen()
            return PaymentAPIClient(
                apiKey: params.apiKey,
                apiRoot: paymentAPIRoot,
                entityId: params.entityId,
                sessionId: session.id,
                session: urlSession
            )
        }
    }

    private func requireOpen() throws {
        if isTornDown { throw PurseCheckoutError.checkoutTornDown }
    }

    // MARK: Submitting

    /// Build the payment: `preValidation` for every split, one `POST /validate`, then each plugin's
    /// `postValidation`.
    @discardableResult
    public func submitPayment(skipOnBeforeValidate: Bool = false) async throws -> ValidationResult {
        try requireOpen()
        try await acquireSubmitLock()

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

        let validator = PaymentValidator(api: try api, registry: registry, configs: configs)
        let result: ValidationResult
        do {
            result = try await validator.execute(
                splits: splitter.splits,
                session: session.source,
                collectedByItem: collectedByItem,
                hooks: hooks,
                skipOnBeforeValidate: skipOnBeforeValidate,
                registrationByItem: currentRegistrations()
            )
        } catch {
            // The session is only spent once /validate actually answered — but there are three
            // distinct ways that can be true, and only one of them used to be handled.
            switch error {
            case let PurseCheckoutError.postValidationFailed(result, _):
                // The API answered about the payment; a plugin choked afterwards. The payment is
                // real, so the session is spent exactly as it would be on the success path.
                validationConsumed = true
                sessionState = result.isSuccess ? .submitted : .error

            case let PurseCheckoutError.validateFailed(_, underlying)
                where (underlying as? PaymentAPIError)?.outcomeUnknown == true:
                // No answer came back, so the payment may exist: a retry could double-charge.
                validationConsumed = true
                sessionState = .submitted

            case _ where Self.isSessionTerminal(error):
                // Already submitted / expired / gone: every further call against this session is
                // pointless, so say so rather than leaving it looking submittable.
                sessionState = .terminated

            default:
                // A hook that aborted before anything was sent, or a transport failure: the
                // checkout is exactly as submittable as it was.
                sessionState = .ready
            }
            throw error
        }

        validationConsumed = true
        sessionState = .submitted
        return result
    }

    /// Present the redirect the last `/validate` asked for, if there is one. Returns `nil` when no
    /// redirect is required — the common case, and **not** an error.
    @discardableResult
    public func presentRedirectIfNeeded(
        for result: ValidationResult,
        using presenter: any RedirectPresenter
    ) async throws -> RedirectOutcome? {
        guard let action = pendingRedirect(for: result) else { return nil }

        if let onRedirection = hooks?.onRedirection {
            do {
                // `true` means the merchant took it over: the SDK opens nothing.
                if try await onRedirection(action) { return nil }
            } catch {
                throw PurseCheckoutError.hookFailed(
                    hook: "onRedirection",
                    underlying: error,
                    code: .postValidateFailed
                )
            }
        }

        return try await presenter.present(action)
    }

    /// The redirect the last `/validate` asked for, if any. Reaching the returned action's
    /// destination is **not** an outcome: the final redirect is built server-side and can land on a
    /// URL this client cannot read.
    public func pendingRedirect(for result: ValidationResult) -> RedirectAction? {
        let primary = splitter.primaryMethod
        return RedirectionResolver.resolve(
            validateResponse: result.raw,
            partner: primary?.partner.wireValue ?? "",
            method: primary?.method.wireValue ?? "",
            sessionReturnURL: session.source.redirection
        )?.withReturnURLPrefix(session.source.redirection)
    }

    /// Whether `error`, **or anything in its `underlying` chain**, is a terminal Payment API answer
    /// for the session (already submitted / expired / gone).
    static func isSessionTerminal(_ error: any Error) -> Bool {
        var current: (any Error)? = error
        while let error = current {
            if (error as? PaymentAPIError)?.isSessionTerminal == true { return true }
            current = (error as? any PurseError)?.underlying
        }
        return false
    }

    /// Re-checks expiry against the server-corrected clock, then moves `ready`/`error` →
    /// `submitting`.
    private func acquireSubmitLock() async throws {
        if validationConsumed {
            throw PurseCheckoutError.submitBlocked(state: .submitted)
        }
        guard sessionState == .ready || sessionState == .error else {
            throw PurseCheckoutError.submitBlocked(state: sessionState)
        }
        // Against the **server** clock, not the device's. A device running ten minutes slow would
        // otherwise submit an expired session, and one running fast would refuse a valid one — and
        // the shopper cannot fix either.
        if await serverClock.isExpiredForServer(session.expirationDate) {
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

    /// The secondary methods this session offers — gift cards, vouchers, loyalty.
    public var secondaryMethods: [SecondaryMethod] {
        paymentMethods.compactMap {
            if case let .secondaryMethod(method) = $0 { return method }
            return nil
        }
    }

    /// The issuer rules driving a secondary method — what the shopper's form should ask for. `nil`
    /// means no configuration is registered for it, so it cannot be tokenized.
    public func secondaryConfig(for method: SecondaryMethod) -> (any SecondaryConfig)? {
        configs.config(for: method)
    }

    /// Turn a typed gift card / voucher into a token that can be drawn into the split. Validates
    /// against the issuer's own PAN/CVV rules before touching the network.
    public func getSecondaryToken(
        method: SecondaryMethod,
        pan: String,
        cvv: String? = nil
    ) async throws -> SecondaryToken {
        do {
            return try await SecondaryTokenizer(api: api, configs: configs)
                // What the instrument is being asked to cover, not 0: an issuer that computes the
                // eligible balance against the requested amount answers 0 to a 0, and the card then
                // looks empty.
                .tokenize(method: method, pan: pan, cvv: cvv, amount: splitter.remaining)
        } catch {
            // A terminal API answer ends the whole session, not just this tokenization — web's
            // `onSessionTerminated` path, and Android's `if (e.sessionTerminal())` here.
            if Self.isSessionTerminal(error) { sessionState = .terminated }
            throw error
        }
    }

    /// Draw a tokenized secondary instrument into the split. See
    /// ``PursePaymentSplitter/takeSplit(_:requestedAmount:)`` for the refusal rules.
    public func applySecondary(_ token: SecondaryToken, amount: Decimal? = nil) throws {
        try splitter.takeSplit(token, requestedAmount: amount)
        refresh()
    }

    /// Draw a saved gift card into the split. Re-reads the checkout's **current** copy rather than
    /// trusting the caller's: a saved card starts at `balance = 0, balanceResolved = false` until
    /// the background `/init` answers, and a merchant holding a value type captured before that
    public func applySecondary(_ token: SavedSecondaryToken, amount: Decimal? = nil) throws {
        let current = savedSecondaryTokens.first { $0.id == token.id } ?? token

        if let disabled = current.disabled {
            throw PurseCheckoutError.secondaryTokenizationFailed(
                "saved token \(current.id) is disabled (\(disabled.code.rawValue))",
                .failedToInitSecondaryToken
            )
        }
        guard current.balanceResolved else {
            throw PurseCheckoutError.secondaryTokenizationFailed(
                "saved token \(current.id) has no resolved balance yet",
                .secondaryTokenEmptyBalance
            )
        }
        guard current.balance > 0 else {
            throw PurseCheckoutError.secondaryTokenizationFailed(
                "saved token \(current.id) has no balance",
                .secondaryTokenEmptyBalance
            )
        }

        try applySecondary(current.asSecondaryToken(), amount: amount)
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
        try requireOpen()
        // Never while a submit is in flight. `submitPayment` suspends at `await validator.execute`,
        // releasing the main actor, and a `setSession` landing in that window replaces the session,
        // resets the splitter and clears `validationConsumed` — so when `/validate` answers, the
        guard sessionState != .submitting else {
            throw PurseCheckoutError.submitBlocked(state: .submitting)
        }

        let newParams = try SessionCodec.decode(widgetData)
        let incoming = newParams.paymentSession

        // The device clock, deliberately: this path is synchronous, and the check that actually
        // gates a payment is the server-corrected one in `acquireSubmitLock`. A device clock wrong
        // enough to slip an expired blob past here still cannot get it submitted.
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

        let built = PaymentSessionBuilder.build(
            incoming,
            disabledMethods: disabledMethods,
            configs: configs
        )
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
        // The blob too, not just the decoded params: `saveState()` serialises this, so leaving it
        // pinned to the first session meant a restore rebuilt a **superseded** one — matched
        // `primaryId` and `secondaries` against the wrong catalogue, on a session that is typically
        self.widgetData = widgetData
        session = built
        meansOfPayment = built.meansOfPayment
        fulfilledByItem = fulfilledByItem.filter { survivingIds.contains($0.key) }
        // Save-token decisions belong to the item that was on screen when the shopper made them.
        registrationByMethod = registrationByMethod.filter { survivingIds.contains($0.key) }
        registrationBySecondaryToken.removeAll()

        // Gift cards were tokenized against the old session and cannot carry over.
        splitter.reset(orderAmount: built.amount)
        if let previousPrimaryId, survivingIds.contains(previousPrimaryId) {
            restorePrimary(id: previousPrimaryId)
        }

        collectedByItem.removeAll()
        validationConsumed = false
        sessionState = .ready
        refresh()
        resolveSavedSecondaryBalances()
        // The wallet session outlives any one payment session — reapply what it already knows onto
        // the freshly rebuilt items rather than fetching again.
        if wallet.client != nil { syncWalletTokens() }
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

    // MARK: Saved secondary token balances

    /// Re-`/init` every saved gift card to learn its balance — sequentially on one `Task`, because
    /// `InitGuard` coalesces concurrent `/init`s of the same `(partner, method, amount)` and two
    /// saved cards of one issuer would otherwise share a single answer.
    private(set) var pendingSecondaryBalanceResolution: Task<Void, Never>?

    private func resolveSavedSecondaryBalances() {
        let saved = meansOfPayment.compactMap { item -> SavedSecondaryToken? in
            if case let .savedSecondaryToken(token) = item { return token }
            return nil
        }
        // `try?`, not `try`: this fires from `init`/`setSession`, neither of which can be torn
        // down yet, and a pathological same-tick `teardown()` should just skip the resolution
        // rather than propagate — nothing here is a merchant-visible entry point to fail loudly.
        guard !saved.isEmpty, let api = try? api else {
            pendingSecondaryBalanceResolution = nil
            return
        }

        pendingSecondaryBalanceResolution = Task {
            for token in saved {
                await self.resolveSavedSecondaryBalance(token, api: api)
            }
        }
    }

    private func resolveSavedSecondaryBalance(_ token: SavedSecondaryToken, api: PaymentAPIClient) async {
        guard let config = configs.config(partner: token.partner, method: token.method) else {
            updateSavedSecondary(token.id) { $0.disabled = .tokenInitFailed }
            return
        }

        let method = SecondaryMethod(
            id: "\(token.partner.wireValue)-\(token.method.wireValue)",
            partner: token.partner,
            method: token.method,
            configuration: token.configuration,
            disabled: nil
        )
        let payload: [String: JSONValue] = [
            "partner": .string(token.partner.wireValue),
            "method": .string(token.method.wireValue),
            "amount": .number(splitter.remaining.description),
            "payment_data": .object(config.buildInitPaymentData(pan: token.pan, cvv: token.cvv))
        ]

        do {
            let response = try await api.initPayment(payload)
            let parsed = try config.parseToken(
                method: method, initResponse: response, pan: token.pan, cvv: token.cvv
            )
            updateSavedSecondary(token.id) {
                $0.balance = parsed.balance
                $0.totalBalance = parsed.totalBalance
                $0.balanceResolved = true
            }
        } catch let error as PaymentAPIError where error.isSessionTerminal {
            // A terminal API answer ends the whole session (web's `onSessionTerminated`); anything
            // else dims just this token — it stays listed, technically disabled.
            sessionState = .terminated
        } catch {
            updateSavedSecondary(token.id) { $0.disabled = .tokenInitFailed }
        }
    }

    /// Mutate one saved gift card in place and republish — a no-op if `setSession` already rebuilt
    /// the list away from under an in-flight resolution.
    private func updateSavedSecondary(_ tokenId: String, _ transform: (inout SavedSecondaryToken) -> Void) {
        guard let index = meansOfPayment.firstIndex(where: {
            if case let .savedSecondaryToken(token) = $0 { return token.id == tokenId }
            return false
        }), case var .savedSecondaryToken(token) = meansOfPayment[index] else { return }

        transform(&token)
        meansOfPayment[index] = .savedSecondaryToken(token)
        refresh()
    }

    // MARK: Wallet session

    /// Exposed at `internal` access only so tests can `await` the initial wallet sync fired at
    /// construction — a merchant has no need to touch it.
    private(set) var pendingWalletSync: Task<Void, Never>?

    /// Overlay the wallet's already-fetched names/favorites onto the session's token items — web's
    /// subscription. No network call: the wallet session outlives any one payment session, so
    /// `setSession` calls this again on the freshly rebuilt items rather than fetching anew.
    private func syncWalletTokens() {
        meansOfPayment = meansOfPayment.map { item in
            switch item {
            case let .paymentToken(original):
                guard let walletToken = wallet.tokens.first(where: { $0.id == original.id }) else { return item }
                var token = original
                if let favorite = walletToken.favorite { token.favorite = favorite }
                if let name = walletToken.name { token.name = name }
                return .paymentToken(token)
            case let .savedSecondaryToken(original):
                guard let walletToken = wallet.tokens.first(where: { $0.id == original.id }) else { return item }
                var token = original
                if let favorite = walletToken.favorite { token.favorite = favorite }
                if let name = walletToken.name { token.name = name }
                return .savedSecondaryToken(token)
            default:
                return item
            }
        }
        refresh()
    }

    // MARK: Registration (save-at-submit)

    /// The current save-token decision for `method` (defaults from its `SaveTokenMode`).
    public func registrationOf(_ method: PrimaryMethod) -> RegistrationState {
        registrationByMethod[method.id] ?? RegistrationState(registered: method.saveTokenMode.registeredByDefault)
    }

    /// Decide whether `method`'s fresh card should be saved at `/validate`, optionally under `name`
    /// — web's `method.register(value, {name})`. The label must match web's `^[a-zA-Z0-9\s]{1,25}$`
    /// and be unique across saved tokens.
    public func register(_ method: PrimaryMethod, registered: Bool = true, name: String? = nil) throws {
        guard method.canBeRegistered else {
            throw PurseCheckoutError.walletOperationFailed(
                "\(method.id) cannot be registered (save_token_mode=\(method.saveTokenMode))",
                .methodNotRegisterable
            )
        }
        if let name { try validateTokenLabel(name, excludingTokenId: nil) }
        registrationByMethod[method.id] = RegistrationState(
            registered: registered, name: name ?? registrationByMethod[method.id]?.name
        )
    }

    /// The current save decision for a **temporary** gift card (one the shopper just typed and
    /// tokenized) — defaults from its method's `SaveTokenMode`, like primaries. Always
    /// `registered == false` for a saved instrument: it is already saved.
    public func registrationOf(_ token: SecondaryToken) -> RegistrationState {
        token.isSaved
            ? RegistrationState(registered: false)
            : registrationBySecondaryToken[token.id]
                ?? RegistrationState(registered: token.saveTokenMode.registeredByDefault)
    }

    /// Ask to keep a temporary gift card for the next session, optionally under `name` — web's
    /// `temporaryToken.register(value, {name})`.
    public func registerSecondary(_ token: SecondaryToken, registered: Bool = true, name: String? = nil) throws {
        guard token.canBeRegistered else {
            throw PurseCheckoutError.walletOperationFailed(
                token.isSaved
                    ? "\(token.id) is already a saved instrument"
                    : "\(token.id) cannot be registered (save_token_mode=\(token.saveTokenMode))",
                .tokenNotRegisterable
            )
        }
        if let name { try validateTokenLabel(name, excludingTokenId: nil) }
        registrationBySecondaryToken[token.id] = RegistrationState(
            registered: registered, name: name ?? registrationBySecondaryToken[token.id]?.name
        )
    }

    /// One `RegistrationState` per currently-split item that carries a save decision — a
    /// `PrimaryMethod` always (even an explicit `false`), a `SecondaryToken` only when it
    /// ``SecondaryToken/canBeRegistered``.
    private func currentRegistrations() -> [String: RegistrationState] {
        var registrations: [String: RegistrationState] = [:]
        for split in splitter.splits {
            if let method = split.source as? PrimaryMethod {
                registrations[method.id] = registrationOf(method)
            } else if let token = split.source as? SecondaryToken, token.canBeRegistered {
                registrations[token.id] = registrationOf(token)
            }
        }
        return registrations
    }

    // MARK: Wallet token management

    /// Rename a saved card (`PATCH …/tokens/{id}/name`) — web's `token.edit({name})`. Needs a
    /// wallet session and the token present in the wallet.
    public func editToken(_ token: PaymentToken, name: String) async throws {
        let client = try wallet.requireClient()
        try wallet.requireToken(token.id)
        try validateTokenLabel(name, excludingTokenId: token.id)
        try await client.editTokenName(token.id, name: name)
        updateTokenItem(token.id) { $0.name = name }
    }

    /// Rename a saved gift card (`PATCH …/tokens/{id}/name`) — same rules as the card overload.
    public func editToken(_ token: SavedSecondaryToken, name: String) async throws {
        let client = try wallet.requireClient()
        try wallet.requireToken(token.id)
        try validateTokenLabel(name, excludingTokenId: token.id)
        try await client.editTokenName(token.id, name: name)
        updateSavedSecondary(token.id) { $0.name = name }
    }

    /// Delete a saved card (`DELETE …/tokens/{id}`) — web's `token.delete()`: also clears it from
    /// the split and removes it from ``paymentTokens``.
    public func deleteToken(_ token: PaymentToken) async throws {
        let client = try wallet.requireClient()
        try wallet.requireToken(token.id)
        try await client.deleteToken(token.id)
        if splitter.primaryMethod?.id == token.id { splitter.setPrimary(nil) }
        meansOfPayment.removeAll { $0.id == token.id }
        wallet.forget(token.id)
        refresh()
    }

    /// Toggle a saved card's favorite flag — web's `token.setAsFavorite()`: optimistic local
    /// update, reverted if the wallet call fails.
    public func setTokenFavorite(_ token: PaymentToken) async throws {
        let client = try wallet.requireClient()
        try wallet.requireToken(token.id)
        let newFavorite = !token.favorite
        updateTokenItem(token.id) { $0.favorite = newFavorite }
        do {
            try await client.setAsFavorite(token.id, favorite: newFavorite)
            _ = try await wallet.fetch()
            syncWalletTokens()
        } catch {
            updateTokenItem(token.id) { $0.favorite = !newFavorite }
            throw error
        }
    }

    /// Delete every wallet token — web's `deleteAllTokens()`.
    public func deleteAllTokens() async throws {
        let client = try wallet.requireClient()
        try await client.deleteAllTokens()
        let tokenIds = Set(paymentTokens.map(\.id))
        if let primaryId = splitter.primaryMethod?.id, tokenIds.contains(primaryId) {
            splitter.setPrimary(nil)
        }
        // Saved gift cards are wallet tokens too — gone with the rest, and out of the split.
        for item in meansOfPayment {
            if case let .savedSecondaryToken(token) = item { splitter.clearSplit(token.asSecondaryToken()) }
        }
        meansOfPayment.removeAll {
            switch $0 {
            case .paymentToken, .savedSecondaryToken: true
            default: false
            }
        }
        wallet.clear()
        refresh()
    }

    private func validateTokenLabel(_ name: String, excludingTokenId: String?) throws {
        let taken = (paymentTokens.map { ($0.id, $0.name) } + savedSecondaryTokens.map { ($0.id, $0.name) })
            .filter { $0.0 != excludingTokenId }
            .map(\.1)
        try wallet.validateLabel(name, takenNames: taken, excludingTokenId: excludingTokenId)
    }

    /// Mutate one saved card in place and republish.
    private func updateTokenItem(_ tokenId: String, _ transform: (inout PaymentToken) -> Void) {
        guard let index = meansOfPayment.firstIndex(where: {
            if case let .paymentToken(token) = $0 { return token.id == tokenId }
            return false
        }), case var .paymentToken(token) = meansOfPayment[index] else { return }

        transform(&token)
        meansOfPayment[index] = .paymentToken(token)
        refresh()
    }

    // MARK: Loan simulation

    /// One BNPL instalment schedule for `method` at `product`'s amount — gated on the method's own
    /// `simulable` label (`configuration.labels.contains("simulable")`).
    public func simulateLoan(_ method: PrimaryMethod, product: LoanProduct) async throws -> LoanSimulation {
        guard method.simulable else { throw PurseCheckoutError.methodNotSimulable(itemId: method.id) }
        do {
            return try await api.getSimulation(partner: method.partner, method: method.method, product: product)
        } catch {
            throw Self.asLoanSimulationFailureOrSelf(error)
        }
    }

    /// Every instalment schedule `method` offers for `product`'s amount — same gate as
    /// ``simulateLoan(_:product:)``.
    public func simulateLoans(_ method: PrimaryMethod, product: LoanProduct) async throws -> [LoanSimulation] {
        guard method.simulable else { throw PurseCheckoutError.methodNotSimulable(itemId: method.id) }
        do {
            return try await api.getSimulationMulti(partner: method.partner, method: method.method, product: product)
        } catch {
            throw Self.asLoanSimulationFailureOrSelf(error)
        }
    }

    /// Every API-level refusal (a 409 `EMPTY_SIMULATION`, say) surfaces as
    /// ``PurseCheckoutError/loanSimulationFailed(_:underlying:)``; only a transport failure with no
    /// HTTP status at all stays the raw ``PaymentAPIError``.
    private static func asLoanSimulationFailureOrSelf(_ error: any Error) -> any Error {
        guard let apiError = error as? PaymentAPIError,
              apiError.errorCode == "INVALID_LOAN_SIMULATION" || apiError.status != nil
        else { return error }
        return PurseCheckoutError.loanSimulationFailed(apiError.message, underlying: apiError)
    }

    // MARK: State restoration

    /// Snapshot this checkout for ``restore(_:hooks:registry:secondaryConfigs:urlSession:)`` after
    /// process death: the session's `widget.data`, the primary selection, the applied gift cards
    /// and their slices, the save decisions, what the native steps collected (JSON-representable
    public func saveState() throws -> CheckoutSavedState {
        try requireOpen()
        let secondaries: [(token: SecondaryToken, amount: Decimal)] = splitter.splits.compactMap { split in
            (split.source as? SecondaryToken).map { ($0, split.amount) }
        }
        return CheckoutSavedState(
            widgetData: widgetData,
            lockedEnvironment: lockedEnvironment,
            disabledMethods: disabledMethods,
            instanceId: instanceId,
            primaryId: splitter.primaryMethod?.id,
            secondaries: secondaries,
            registrationByMethod: registrationByMethod,
            registrationBySecondaryToken: registrationBySecondaryToken,
            collectedByItem: collectedByItem,
            submitted: validationConsumed || sessionState == .submitting || sessionState == .submitted,
            savedAt: Date()
        )
    }

    /// Rebuild a checkout from a ``CheckoutSavedState`` — after the process was killed while the
    /// shopper was in a bank app, PayPal or a 3-D Secure page.
    public static func restore(
        _ state: CheckoutSavedState,
        hooks: PurseCheckoutHooks? = nil,
        registry: PluginRegistry = .shared,
        secondaryConfigs: SecondaryConfigs = .shared,
        urlSession: URLSession = .shared
    ) throws -> PurseHeadlessCheckout {
        let checkout = try PurseHeadlessCheckout(
            widgetData: state.widgetData,
            lockedEnvironment: state.lockedEnvironment,
            disabledMethods: state.disabledMethods,
            hooks: hooks,
            registry: registry,
            secondaryConfigs: secondaryConfigs,
            instanceId: state.instanceId,
            urlSession: urlSession
        )
        checkout.applySavedState(state)
        return checkout
    }

    private func applySavedState(_ state: CheckoutSavedState) {
        registrationByMethod.merge(state.registrationByMethod) { _, new in new }
        registrationBySecondaryToken.merge(state.registrationBySecondaryToken) { _, new in new }
        for (id, data) in state.collectedByItem { collectedByItem[id] = data }
        for (token, amount) in state.secondaries {
            // A slice the new session cannot honour (a smaller order, a spent usage limit) is
            // dropped rather than failing the whole restore.
            try? splitter.takeSplit(token, requestedAmount: amount)
        }
        if let primaryId = state.primaryId { restoreSavedPrimary(id: primaryId) }
        if state.submitted { markSubmittedBeforeDeath() }
        refresh()
    }

    /// Distinct from ``restorePrimary(id:)``, which `setSession` uses for a primary already known
    /// to survive: a saved primary might no longer be selectable at all (disabled, or gone), so
    /// this checks first and skips silently rather than assuming.
    private func restoreSavedPrimary(id: String) {
        guard let item = meansOfPayment.first(where: { $0.id == id }), item.disabled == nil else { return }
        switch item {
        case let .primaryMethod(method):
            splitter.setPrimary(method)
        case let .paymentToken(token):
            // Armed at selection, as setPrimaryToken does: a CVV-gated token stays unfulfilled
            // until its form says otherwise.
            if token.requiresCVV { fulfilledByItem[token.id] = fulfilledByItem[token.id] ?? false }
            splitter.setPrimary(token)
        default:
            break
        }
    }

    /// A `/validate` left the device before the process died: the session's one submit is spent
    /// whatever the answer was. Never send another; the merchant confirms the outcome.
    private func markSubmittedBeforeDeath() {
        validationConsumed = true
        if sessionState != .expired, sessionState != .terminated {
            sessionState = .submitted
        }
    }

    // MARK: Teardown

    /// Releases everything this checkout owns — cancels any in-flight background work (the saved
    /// secondary token balance resolution, the wallet sync) and marks the checkout closed. Web's
    /// `teardown()`.
    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        pendingSecondaryBalanceResolution?.cancel()
        pendingWalletSync?.cancel()
        pendingClockSync?.cancel()
        // Otherwise it keeps waking every five seconds for the life of the process. It holds `self`
        // weakly so it would end on deallocation anyway, but a merchant who tears down and keeps
        // the object around is exactly who called this.
        expiryWatchdog?.cancel()
    }
}
