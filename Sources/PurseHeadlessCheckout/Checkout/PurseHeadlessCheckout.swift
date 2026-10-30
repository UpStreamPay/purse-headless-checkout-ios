// Web: packages/headless-checkout/src/headless-checkout.ts
// Same: session in force, method list, split, fulfilment, setSession survivor rules.
// Differs: @Published properties rather than Svelte stores / StateFlow; plugin events through a callback; with no redirect, falls back on the session's `success`/`failure` URL rather than `redirection`.

import Combine
import Foundation
import UIKit

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

    /// Locale, theme and card-form texts handed to every plugin this checkout builds. Android's
    /// `options`; without it a merchant's `PurseTheme` cannot reach the card form.
    public let options: PluginOptions

    /// Resolved Payment API root; calls go to `{root}/{entityId}/sessions/{sessionId}/…`.
    ///
    /// Re-resolved by ``setSession(_:)``, since the new blob may name a different host.
    public private(set) var paymentAPIRoot: String

    public var currency: String { session.currency }
    public var isInformationRequest: Bool { session.isInformationRequest }
    public var currentSessionId: String { session.id }

    private let environment: PurseEnvironment
    /// The override as passed, kept apart from the resolved ``environment`` because `setSession`
    /// and `saveState` need the *decision*, not its result.
    private let lockedEnvironment: PurseEnvironment?
    /// Locked, or downgraded by ``PurseEnvironment/resolve(_:isDebugHost:)``: either way the
    /// session's `api_url` is not trusted.
    private let ignoresDeclaredAPIRoot: Bool
    /// Kept so `saveState()` can round-trip the exact session `restore` rebuilds from.
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
    /// The app-background flush observer, removed at `teardown()`.
    private var backgroundObserver: (any NSObjectProtocol)?
    var expiryWatchdog: Task<Void, Never>?
    /// Injectable so tests can stub the transport — the seam `purse-ios-securefields` calls
    /// `testURLSession`. Production callers never pass it.
    private let urlSession: URLSession
    private let wallet: WalletTokens
    /// This checkout's own analytics bus — per-instance, not a process-wide singleton; see
    /// `CheckoutEventBus`'s own header comment for why.
    private let eventBus = CheckoutEventBus()
    /// Save-token decisions for a fresh primary method, keyed by item id.
    private var registrationByMethod: [String: RegistrationState] = [:]
    /// Save-token decisions for a temporary secondary instrument, keyed by item id.
    private var registrationBySecondaryToken: [String: RegistrationState] = [:]
    /// Items already given their plugin's `onSessionSet` — `host(for:)` fires it exactly once per
    /// item, Android's `activePlugins` gate. Kept with their plugin so `onAmountUpdate` can reach it.
    private var trackedPlugins: [String: (item: any PrimarySource, plugin: any PartnerUIPlugin)] = [:]
    /// The remaining amount tracked plugins were last told about.
    private var lastNotifiedRemaining: Decimal?
    /// Test seam: the fire-and-forget `onSessionSet` `Task` started by `host(for:)`, keyed by item
    /// id, so a test can `await` it instead of racing the checkout's own background work.
    var pendingSessionSet: [String: Task<Void, Never>] = [:]

    /// Every ``PluginEvent`` a partner's native step reports, after the checkout has reacted to it —
    /// Android's `pluginEvents`.
    public var onPluginEvent: ((CheckoutPluginEvent) -> Void)?

    // MARK: Creation

    /// - Parameters: - widgetData: the base64 `widget.data` string from your backend's Client
    /// Session response. - lockedEnvironment: overrides whatever `widgetData` declares — including
    /// its `api_url`: the tier's built-in root (`…/payment/v1`) is used instead.
    public convenience init(
        widgetData: String,
        lockedEnvironment: PurseEnvironment? = nil,
        disabledMethods: Set<MethodKey> = [],
        hooks: PurseCheckoutHooks? = nil,
        registry: PluginRegistry = .shared,
        secondaryConfigs: SecondaryConfigs = .shared,
        instanceId: String = UUID().uuidString,
        urlSession: URLSession = .shared,
        walletAPIRootOverride: String? = nil,
        monitoringAPIRootOverride: String? = nil,
        restored: Bool = false,
        options: PluginOptions = PluginOptions()
    ) throws {
        try self.init(
            widgetData: widgetData,
            lockedEnvironment: lockedEnvironment,
            disabledMethods: disabledMethods,
            hooks: hooks,
            registry: registry,
            secondaryConfigs: secondaryConfigs,
            instanceId: instanceId,
            urlSession: urlSession,
            walletAPIRootOverride: walletAPIRootOverride,
            monitoringAPIRootOverride: monitoringAPIRootOverride,
            restored: restored,
            options: options,
            serverClockOverride: nil
        )
    }

    /// Designated, and internal: `serverClockOverride` and `isDebugHostOverride` are test seams
    /// with no production caller, so they stay out of the SDK's semver contract.
    init(
        widgetData: String,
        lockedEnvironment: PurseEnvironment? = nil,
        disabledMethods: Set<MethodKey> = [],
        hooks: PurseCheckoutHooks? = nil,
        registry: PluginRegistry = .shared,
        secondaryConfigs: SecondaryConfigs = .shared,
        instanceId: String = UUID().uuidString,
        urlSession: URLSession = .shared,
        walletAPIRootOverride: String? = nil,
        monitoringAPIRootOverride: String? = nil,
        restored: Bool = false,
        options: PluginOptions = PluginOptions(),
        isDebugHostOverride: Bool? = nil,
        serverClockOverride: ServerDatetimeChecker?
    ) throws {
        let params = try SessionCodec.decode(widgetData)
        self.params = params
        self.widgetData = widgetData
        self.lockedEnvironment = lockedEnvironment
        let requested = lockedEnvironment ?? params.environment
        let environment = PurseEnvironment.resolve(requested, isDebugHost: isDebugHostOverride ?? PurseEnvironment.isDebugHost)
        self.environment = environment
        self.ignoresDeclaredAPIRoot = lockedEnvironment != nil || environment != requested
        self.paymentAPIRoot = Self.resolveAPIRoot(params, locked: ignoresDeclaredAPIRoot, environment: environment)
        self.disabledMethods = disabledMethods
        self.options = options
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
        // Injectable only so a test can hold the clock long enough to observe the submit latch's
        // suspension window. Production callers never pass it.
        self.serverClock = serverClockOverride
            ?? ServerDatetimeChecker(fetchServerTime: { try await datetimeAPI.datetime() })

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
        runEligibilityChecks()
        // Only with a `wallet_session`. Failures are swallowed: the wallet gates management
        // operations and syncs names, so it must never break the checkout.
        if wallet.client != nil {
            pendingWalletSync = Task {
                do {
                    _ = try await self.wallet.fetch()
                    self.syncWalletTokens()
                    await self.eventBus.post(.setWalletSession, .info, monitoringPayload([
                        "walletSessionId": (params.walletSession?.sessionId).map(JSONValue.string)
                    ]))
                } catch {
                    await self.eventBus.post(.setWalletSessionFailed, .error, errorPayload(error))
                }
            }
        }

        let monitoringClient = MonitoringAPIClient(
            apiKey: params.apiKey,
            monitoringAPIRoot: monitoringAPIRootOverride ?? environment.monitoringAPIRoot,
            envWireValue: environment.wireValue,
            // The injected transport, like every other client here — otherwise tests and the Demo
            // POST real telemetry to the live host, unseen by any stub.
            session: urlSession
        )
        let createPayload = monitoringPayload([
            "sessionType": .string("v2"),
            "user_agent": .string(CheckoutMonitoringContext.userAgent()),
            "device": CheckoutMonitoringContext.deviceContext(),
            "screen": CheckoutMonitoringContext.screen(),
            "restored": restored ? .bool(true) : nil
        ])
        let setSessionPayload = monitoringPayload([
            "paymentSessionId": .string(built.id),
            "sessionType": .string("v2"),
            "nb_methods": .number(String(built.meansOfPayment.count))
        ])
        pendingMonitoringInstall = Task {
            await self.eventBus.install(client: monitoringClient, instanceId: instanceId)
            await self.eventBus.patchExtras(
                entityId: params.entityId,
                paymentSessionId: built.id,
                walletSessionId: params.walletSession?.sessionId,
                version: SDKVersion.value,
                wrapper: "direct"
            )
            await self.eventBus.post(.create, .info, createPayload)
            await self.eventBus.post(.setSession, .info, setSessionPayload)
            await self.eventBus.post(.ready)
        }
        observeAppBackgrounding()

        // Nothing else ever called `sync()`, so the offset stayed 0 and every "server-corrected"
        // check was really the device clock. One sync at creation is what makes the correction real.
        pendingClockSync = Task { [serverClock] in await serverClock.sync() }
        startExpiryWatchdog()
    }

    /// Flush queued telemetry when the app goes to the background.
    private func observeAppBackgrounding() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.eventBus.flush() }
        }
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
        locked: Bool,
        environment: PurseEnvironment
    ) -> String {
        guard !locked, let declared = params.apiURL.nonBlank else { return environment.paymentAPIRoot }
        return declared
    }

    /// The Payment API client for the session in force. Every network path goes through here, so
    /// one guard covers them all — web's `apiClient()`.
    private var api: PaymentAPIClient {
        get throws {
            try requireOpen()
            var client = PaymentAPIClient(
                apiKey: params.apiKey,
                apiRoot: paymentAPIRoot,
                entityId: params.entityId,
                sessionId: session.id,
                session: urlSession
            )
            client.monitor = { [eventBus] code, level, payload in
                Task { await eventBus.post(code, level, payload) }
            }
            return client
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
        await eventBus.post(.submitPayment, .info, monitoringPayload([
            "trigger": .string(skipOnBeforeValidate ? "xpay" : "api"),
            "nb_splits": .number(String(splitter.splits.count))
        ]))
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

        await eventBus.post(.validationStarted, .info, monitoringPayload([
            "session_id": .string(session.id), "nb_items": .number(String(splitter.splits.count))
        ]))

        let validator = PaymentValidator(api: try api, registry: registry, configs: configs, eventBus: eventBus)
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

            case let PurseCheckoutError.noPluginRegistered(itemId):
                sessionState = .ready
                deactivateUnserved(itemId)

            case _ where Self.isSessionTerminal(error):
                // Already submitted / expired / gone: every further call against this session is
                // pointless, so say so rather than leaving it looking submittable.
                sessionState = .terminated

            default:
                // A hook that aborted before anything was sent, or a transport failure: the
                // checkout is exactly as submittable as it was.
                sessionState = .ready
            }
            await eventBus.post(.paymentError, .error, errorPayload(error))
            throw error
        }

        validationConsumed = true
        sessionState = .submitted
        // Web's levels: a refused payment is a WARNING on validationFailed and an ERROR on the
        // paymentError that follows it, both saying why attempt by attempt.
        let attempts = summarizeValidationResults(result.raw)
        if result.isSuccess {
            await eventBus.post(.validationSuccess, .success, monitoringPayload([
                "global_status": .string(result.globalStatus), "results": attempts
            ]))
        } else {
            await eventBus.post(.validationFailed, .warning, monitoringPayload([
                "global_status": .string(result.globalStatus), "results": attempts
            ]))
            await eventBus.post(.paymentError, .error, monitoringPayload([
                "message": .string("validate answered \(result.globalStatus)"),
                "api_status": .string(result.globalStatus),
                "has_redirection": .bool(result.redirection?.url != nil),
                "results": summarizeValidationResults(result.raw, onlyFailures: true)
            ]))
        }
        if sessionFallbackRedirect(for: result) != nil {
            await eventBus.post(.paymentError, .error, monitoringPayload([
                "message": .string("Missing redirection URL in validate response, falling back to session URL"),
                "api_status": .string(result.globalStatus),
                "has_redirection": .bool(false)
            ]))
        }
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
                await eventBus.post(.clientHookError, .error, monitoringPayload([
                    "hook": .string("onRedirection"), "message": .string(error.localizedDescription)
                ]))
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
        responseRedirect(for: result) ?? sessionFallbackRedirect(for: result)
    }

    /// The redirect the `/validate` answer itself asks for — a step the payment still needs.
    func responseRedirect(for result: ValidationResult) -> RedirectAction? {
        let primary = splitter.primaryMethod
        return RedirectionResolver.resolve(
            validateResponse: result.raw,
            partner: primary?.partner.wireValue ?? "",
            method: primary?.method.wireValue ?? "",
            sessionReturnURL: session.source.redirection
        )?.withReturnURLPrefix(session.source.redirection)
    }

    /// Web's fallbacks when `/validate` names no redirect: after a success with no primary (or no
    /// `results`), and after a failure. Web uses `session.redirection` for both; iOS sends the
    /// shopper to `success` or `failure`, and never on a pending answer. Only a page to show — the
    /// `/validate` answer is already the outcome.
    func sessionFallbackRedirect(for result: ValidationResult) -> RedirectAction? {
        guard result.redirection?.url == nil, result.redirection?.form == nil,
              responseRedirect(for: result) == nil
        else { return nil }
        let url: String?
        switch result.status {
        case .success:
            let results = result.raw["results"]?.arrayValue ?? []
            guard splitter.primaryMethod == nil || results.isEmpty else { return nil }
            url = session.source.success?.nonBlank
        case .failed, .error:
            url = session.source.failure?.nonBlank
        case .uncertain, .waiting, .unknown:
            return nil
        }
        let returnURL = session.source.redirection
        // Opening the session's own return URL shows nothing.
        guard let url, !(returnURL.map(url.hasPrefix) ?? false) else { return nil }
        return .get(url: url, returnURLPrefix: returnURL)
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
            postMonitoring(.submitBlocked, .warning, monitoringPayload(["state": .string(SessionState.submitted.rawValue)]))
            throw PurseCheckoutError.submitBlocked(state: .submitted)
        }
        guard sessionState == .ready || sessionState == .error else {
            postMonitoring(.submitBlocked, .warning, monitoringPayload(["state": .string(sessionState.rawValue)]))
            throw PurseCheckoutError.submitBlocked(state: sessionState)
        }
        // Claimed before the `await` below, not after. `@MainActor` serialises synchronous regions,
        // not whole `async` functions: a suspension ends one region, so a second caller would run
        // during the hop, read `.ready`, and clear the same guard. Two taps, two `/validate`s.
        sessionState = .submitting
        // Against the **server** clock, not the device's. A device running ten minutes slow would
        // otherwise submit an expired session, and one running fast would refuse a valid one — and
        // the shopper cannot fix either.
        if await serverClock.isExpiredForServer(session.expirationDate) {
            sessionState = .expired
            postMonitoring(.expiredSession, .warning, monitoringPayload(["paymentSessionId": .string(session.id)]))
            throw PurseCheckoutError.sessionExpired(sessionId: session.id)
        }
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
            postMonitoring(.clearPrimarySplit)
            refresh()
            return
        }
        try selectPrimary(method, itemId: method.id)
        postMonitoring(.methodSetPrimary, .info, monitoringPayload([
            "partner": .string(method.partner.wireValue), "method": .string(method.method.wireValue)
        ]))
    }

    /// Pay with a saved card. When the token ``PaymentToken/requiresCVV``, the fulfilment gate is
    /// armed: the checkout is not fulfilled until the CVV form reports valid.
    public func setPrimaryToken(_ token: PaymentToken) throws {
        try selectPrimary(token, itemId: token.id)
        postMonitoring(.primaryTokenSetAsPrimary, .info, monitoringPayload([
            "partner": .string(token.partner.wireValue), "method": .string(token.method.wireValue)
        ]))
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
        postMonitoring(.clearPrimarySplit)
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
        await eventBus.post(.methodGetSecondaryToken, .info, monitoringPayload([
            "partner": .string(method.partner.wireValue), "method": .string(method.method.wireValue)
        ]))
        do {
            return try await SecondaryTokenizer(api: api, configs: configs)
                // What the instrument is being asked to cover, not 0: an issuer that computes the
                // eligible balance against the requested amount answers 0 to a 0, and the card then
                // looks empty.
                .tokenize(method: method, pan: pan, cvv: cvv, amount: splitter.remaining)
        } catch {
            // A terminal API answer ends the whole session, not just this tokenization — web's
            // `onSessionTerminated` path, and Android's `if (e.sessionTerminal())` here. Walked
            // through the wrapper, since the tokenizer never rethrows a bare `PaymentAPIError`.
            if Self.isSessionTerminal(error) { sessionState = .terminated }
            throw error
        }
    }

    /// Draw a tokenized secondary instrument into the split. See
    /// ``PursePaymentSplitter/takeSplit(_:requestedAmount:)`` for the refusal rules.
    public func applySecondary(_ token: SecondaryToken, amount: Decimal? = nil) throws {
        try splitter.takeSplit(token, requestedAmount: amount)
        postMonitoring(.secondaryTokenTake, .info, monitoringPayload([
            "partner": .string(token.partner.wireValue),
            "method": .string(token.method.wireValue),
            // Whether the shopper chose the slice, never how much it is.
            "partial": .bool(amount != nil)
        ]))
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
        // Deliberately **not** `token.id`: for a freshly typed instrument that is built as
        // `"{method}-{pan.suffix(4)}"` (`SecondaryConfig`), so emitting it hands the collector the
        // card's last four digits.
        postMonitoring(.secondaryTokenRemoveFromSplit, .info, monitoringPayload([
            "partner": .string(token.partner.wireValue), "method": .string(token.method.wireValue)
        ]))
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

    // MARK: Plugin host

    /// The ``PluginHost`` a coordinator drives `item` through — everything `PartnerUI` needs from
    /// this checkout without depending on `Checkout`.
    public func host(for item: any PrimarySource) throws -> PluginHost {
        try requireOpen()
        let client = try api
        trackPlugin(item, api: client)
        return ItemHost(checkout: self, item: item, apiClient: client)
    }

    // MARK: Payment element

    /// The ``PaymentElement`` for `item` — web's `getPaymentElement`, Android's
    /// `rememberPaymentElement`.
    public func paymentElement(
        for item: PaymentItem,
        listener: any PaymentElementListener,
        redirect: (any RedirectPresenter)? = nil,
        appReturnURL: URL? = nil
    ) -> PaymentElement {
        let wrapped = ElementListener(listener)
        let key = "\(item.id):\(itemGenerations[item.id] ?? 0)"

        func failing(_ error: any PurseError) -> PaymentElement {
            PaymentElement(
                item: item,
                surface: .headless(submit: { wrapped.onOutcome(.failed(error)) }),
                listener: wrapped
            )
        }

        // Swift catches at compile time what Kotlin leaves to runtime: `host(for:)` takes a
        // `PrimarySource`, and a secondary is not one. Android has no peer for this branch.
        let source: any PrimarySource
        let isToken: Bool
        switch item {
        case let .primaryMethod(method): source = method; isToken = false
        case let .paymentToken(token): source = token; isToken = true
        case .secondaryMethod, .savedSecondaryToken:
            return failing(PartnerUIError(
                "a secondary is applied with applySecondary(_:), never paid with a payment element"
            ))
        }

        if let disabled = item.disabled, disabled.isTechnicallyDisabled {
            return failing(PurseCheckoutError.methodDisabled(itemId: item.id, disabled: disabled))
        }

        let host: PluginHost
        do {
            host = try self.host(for: source)
        } catch {
            return failing(error.asPurseError())
        }

        guard let plugin = registry.plugin(partner: item.partner, method: item.method, session: session.source) else {
            // Deferred: this runs inside a SwiftUI body, which must not publish synchronously.
            Task { @MainActor [weak self] in self?.deactivateUnserved(item.id) }
            return failing(PurseCheckoutError.noPluginRegistered(itemId: item.id))
        }
        guard let module = registry.module(rendering: plugin) else {
            return failing(PurseCheckoutError.noPluginRegistered(itemId: item.id))
        }

        postMonitoring(
            isToken ? .primaryTokenGetPaymentElement : .methodGetPaymentElement,
            .info,
            monitoringPayload(["itemId": .string(item.id)])
        )

        let request = SurfaceRequest(
            host: host,
            isToken: isToken,
            key: key,
            listener: wrapped,
            appReturnURL: appReturnURL,
            redirectPresenter: redirect,
            capture: { [weak self] in
                guard let self else { return }
                await ElementFlow.capture(host: host, checkout: self, presenter: redirect, listener: wrapped)
            }
        )

        guard let surface = module.surface(for: plugin, request: request) else {
            return failing(PurseCheckoutError.noPluginRegistered(itemId: item.id))
        }
        return PaymentElement(item: item, surface: surface, listener: wrapped)
    }

    /// The context a plugin sees for `item` right now, against `apiClient` — Android's
    /// `pluginContext`.
    private func pluginContext(for item: any PrimarySource, api apiClient: PaymentAPIClient) -> PartnerUIContext {
        let registration = (item as? PrimaryMethod).map { registrationOf($0).registered } ?? false
        let token = (item as? PaymentToken).map {
            PayToken(
                value: $0.value,
                expirationDate: $0.expirationDate,
                holderName: $0.holderName.nonBlank,
                selectedNetwork: CardBrand.fromWire($0.brand) == .unknown ? nil : $0.brand,
                requiresCVV: $0.requiresCVV
            )
        }
        return PartnerUIContext(
            partner: item.partner,
            method: item.method,
            session: session.source,
            amount: remainingAmountToPay,
            api: apiClient,
            register: registration,
            token: token,
            collected: collectedByItem[item.id] ?? [:],
            options: options,
            dispatchEvent: { [weak self] event in self?.handlePluginEvent(event, from: item) }
        )
    }

    /// Resolve `item`'s plugin and give it `onSessionSet` once — Android's `trackPlugin`. A no-op
    /// when no plugin is registered yet, or `item` was already tracked.
    private func trackPlugin(_ item: any PrimarySource, api apiClient: PaymentAPIClient) {
        guard trackedPlugins[item.id] == nil,
              let plugin = registry.plugin(partner: item.partner, method: item.method, session: session.source)
        else { return }
        trackedPlugins[item.id] = (item, plugin)
        let context = pluginContext(for: item, api: apiClient)
        pendingSessionSet[item.id] = Task {
            try? await plugin.onSessionSet(context)
        }
    }

    /// The adapter behind every ``host(for:)`` call — one shape for every plugin, never exposed
    /// beyond the `PluginHost` existential it returns as.
    @MainActor
    private final class ItemHost: PluginHost {
        unowned let checkout: PurseHeadlessCheckout
        let item: any PrimarySource
        let apiClient: PaymentAPIClient

        init(checkout: PurseHeadlessCheckout, item: any PrimarySource, apiClient: PaymentAPIClient) {
            self.checkout = checkout
            self.item = item
            self.apiClient = apiClient
        }

        var environment: PurseEnvironment { checkout.environment }
        var redirectionReturnURL: String? { checkout.session.source.redirection }

        func buildContext() -> PartnerUIContext {
            checkout.pluginContext(for: item, api: apiClient)
        }

        func setCollected(_ data: [String: JSONValue]) {
            checkout.setCollected(item.id, data)
        }

        func setAsPrimary() throws {
            switch item {
            case let method as PrimaryMethod:
                try checkout.setPrimary(method)
            case let token as PaymentToken:
                try checkout.setPrimaryToken(token)
            default:
                break
            }
        }

        func setFulfilled(_ fulfilled: Bool) {
            checkout.setFulfilled(item.id, fulfilled)
        }

        func submitPayment() async throws -> ValidationResult {
            try await checkout.submitPayment()
        }
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
            postMonitoring(.expiredSession, .warning, monitoringPayload(["paymentSessionId": .string(incoming.id)]))
            throw PurseCheckoutError.sessionExpired(sessionId: incoming.id)
        }
        // Same session id → ignored with no change, as on web.
        if incoming.id == session.id { return }

        let previousSessionId = session.id
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
        paymentAPIRoot = Self.resolveAPIRoot(newParams, locked: ignoresDeclaredAPIRoot, environment: environment)

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
        // The blob too, not just the decoded params: `saveState()` serialises it, so a stale one
        // makes `restore` rebuild a superseded session.
        self.widgetData = widgetData
        session = built
        meansOfPayment = built.meansOfPayment
        fulfilledByItem = fulfilledByItem.filter { survivingIds.contains($0.key) }
        // Save-token decisions belong to the item that was on screen when the shopper made them.
        registrationByMethod = registrationByMethod.filter { survivingIds.contains($0.key) }
        registrationBySecondaryToken.removeAll()
        // A dropped id may be reused by an unrelated item in a later session (ids are
        // `"{partner}-{method}"`, not content hashes) — Android's `activePlugins.filterKeys`/
        // `remove` prune.
        trackedPlugins = trackedPlugins.filter { survivingIds.contains($0.key) }
        for (id, task) in pendingSessionSet where !survivingIds.contains(id) {
            task.cancel()
            pendingSessionSet.removeValue(forKey: id)
        }

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
        runEligibilityChecks()
        // The wallet session outlives any one payment session — reapply what it already knows onto
        // the freshly rebuilt items rather than fetching again.
        if wallet.client != nil { syncWalletTokens() }

        // Re-stamp the envelope so events after this refresh carry the session they belong to, not
        // the first one — web's `patchExtrasData` on every `_setSession`.
        let survivingMethodCount = survivingIds.count
        let meansCount = built.meansOfPayment.count
        Task {
            await self.eventBus.patchExtras(paymentSessionId: built.id, walletSessionId: newParams.walletSession?.sessionId)
            await self.eventBus.post(.setSession, .info, monitoringPayload([
                "paymentSessionId": .string(built.id),
                "previousPaymentSessionId": .string(previousSessionId),
                "sessionType": .string("v2"),
                "nb_methods": .number(String(meansCount)),
                "nb_surviving_methods": .number(String(survivingMethodCount))
            ]))
        }
    }

    /// Fire-and-forget an event from a synchronous context — every mutating method here is
    /// synchronous, but `CheckoutEventBus` is an actor. A failure inside `post` cannot happen (it
    /// never throws), so this never needs to surface anything back to the caller.
    private func postMonitoring(_ code: CheckoutEventCode, _ type: EventLevel = .info, _ payload: JSONValue? = nil) {
        Task { await self.eventBus.post(code, type, payload) }
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
        let before = meansOfPayment
        meansOfPayment = MethodAvailability.recompute(
            meansOfPayment,
            isInformationRequest: session.isInformationRequest,
            primaryReach: splitter.primaryReach,
            splitSources: splitter.splits.map(\.source)
        )
        reportDisabledTransitions(before: before, after: meansOfPayment)
        publishItems()

        remainingAmountToPay = splitter.primaryReach
        amountSplit = splitter.splits
        let fulfilled = splitter.fulfilled && unfulfilledItemId == nil
        if fulfilled != isPaymentFulfilled {
            postMonitoring(.paymentFulfilled, .info, monitoringPayload(["isFulfilled": .bool(fulfilled)]))
        }
        isPaymentFulfilled = fulfilled
        notifyAmountUpdate()
    }

    /// Republish the item lists. On its own, without a recompute, when a state was just set —
    /// `MethodAvailability.recompute` would wipe a recoverable one.
    private func publishItems() {
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
    }

    /// Android's `notifyAmountUpdate`: only when the remaining amount actually moved, to every
    /// tracked plugin, fire-and-forget.
    private func notifyAmountUpdate() {
        let remaining = splitter.primaryReach
        guard remaining != lastNotifiedRemaining else { return }
        let isFirst = lastNotifiedRemaining == nil
        lastNotifiedRemaining = remaining
        guard !isFirst, !trackedPlugins.isEmpty, let client = try? api else { return }
        for (item, plugin) in trackedPlugins.values {
            let context = pluginContext(for: item, api: client)
            Task { try? await plugin.onAmountUpdate(context) }
        }
    }

    // MARK: Plugin events

    /// Android's `onPluginEvent`.
    private func handlePluginEvent(_ event: PluginEvent, from item: any PrimarySource) {
        switch event {
        case .ready:
            clearRecoverableDisabled(item.id)
        case let .initFailed(message), let .clientError(message):
            deactivate(item.id, .partnerUIFatalError(reason: message))
        case let .partnerError(message, recoverable):
            deactivate(item.id, recoverable
                ? .partnerUIRecoverableError(reason: message)
                : .partnerUIFatalError(reason: message))
        case .endOfSession:
            sessionState = .terminated
        case .redirect, .cancelled:
            break
        }

        // Web's `resolveUIEventLevel`.
        let level: EventLevel = switch event {
        case .initFailed, .clientError: .error
        case let .partnerError(_, recoverable): recoverable ? .warning : .error
        default: .info
        }
        postMonitoring(.partnerUIEvent, level, monitoringPayload([
            "code": .string(event.code),
            "partner": .string(item.partner.wireValue),
            "method": .string(item.method.wireValue),
            "reason": event.message.map { .string(String($0.prefix(Self.maxReasonLength))) }
        ]))
        onPluginEvent?(CheckoutPluginEvent(itemId: item.id, event: event))
    }

    static let maxReasonLength = 200

    /// Web's answer to an item no plugin serves (an unknown template, an unlinked product): fatal
    /// at engagement, out of the split and refused for the rest of the session.
    private func deactivateUnserved(_ itemId: String) {
        deactivate(itemId, .partnerUIFatalError(reason: "no plugin serves this method"))
    }

    /// Web's `fatalError` → `clearSplit` + `deactivateMop`.
    private func deactivate(_ itemId: String, _ state: DisabledState) {
        guard let index = meansOfPayment.firstIndex(where: { $0.id == itemId }) else { return }
        let before = meansOfPayment
        meansOfPayment[index] = meansOfPayment[index].withDisabled(state)
        if state.requiresUIClear || state.isFiltered, splitter.primaryMethod?.id == itemId {
            splitter.setPrimary(nil)
            refresh()
            return
        }
        reportDisabledTransitions(before: before, after: meansOfPayment)
        publishItems()
    }

    private func clearRecoverableDisabled(_ itemId: String) {
        guard let index = meansOfPayment.firstIndex(where: { $0.id == itemId }),
              meansOfPayment[index].disabled?.isRecoverable == true
        else { return }
        meansOfPayment[index] = meansOfPayment[index].withDisabled(nil)
        publishItems()
    }

    // MARK: Eligibility

    /// Test seam: the `ensureClientCompatibility` probes started by the last eligibility pass.
    var pendingEligibility: [Task<Void, Never>] = []

    /// Android's `runEligibilityChecks`: name a missing partner product, and let each plugin refuse
    /// a device it cannot run on.
    private func runEligibilityChecks() {
        guard let client = try? api else { return }
        pendingEligibility = meansOfPayment.compactMap { item -> Task<Void, Never>? in
            let source: any PrimarySource
            switch item {
            case let .primaryMethod(method): source = method
            case let .paymentToken(token): source = token
            case .secondaryMethod, .savedSecondaryToken: return nil
            }
            guard let plugin = registry.plugin(partner: item.partner, method: item.method, session: session.source) else {
                if let product = PartnerProducts.product(partner: item.partner, method: item.method) {
                    postMonitoring(.methodDisabled, .warning, monitoringPayload([
                        "partner": .string(item.partner.wireValue),
                        "method": .string(item.method.wireValue),
                        "code": .string("MISSING_PARTNER_ARTIFACT"),
                        "artifact": .string(product)
                    ]))
                }
                return nil
            }
            let context = pluginContext(for: source, api: client)
            return Task { [weak self] in
                do {
                    try await plugin.ensureClientCompatibility(context)
                } catch {
                    guard let self else { return }
                    self.postMonitoring(.partnerUIEvent, .warning, monitoringPayload([
                        "code": .string("pluginIsIncompatibleWithClient"),
                        "partner": .string(item.partner.wireValue),
                        "method": .string(item.method.wireValue),
                        "reason": .string(String(error.asPurseError().message.prefix(Self.maxReasonLength)))
                    ]))
                    self.deactivate(item.id, .pluginIncompatible)
                }
            }
        }
    }

    /// Every transition of an item into a new ``DisabledState`` (or into none) as one
    /// `HEADLESS_CHECKOUT_METHOD_DISABLED` event carrying only the state's **code** — never its
    /// `message`, which can quote amounts.
    private func reportDisabledTransitions(before: [PaymentItem], after: [PaymentItem]) {
        let previousCodes = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.disabled?.code) })
        for item in after {
            guard let state = item.disabled else { continue }
            let previous = previousCodes[item.id] ?? nil
            if previous == state.code { continue }
            let technical = state.isTechnicallyDisabled || state.code == .fatalErrorBeforeRender
            postMonitoring(.methodDisabled, technical ? .warning : .info, monitoringPayload([
                "partner": .string(item.partner.wireValue),
                "method": .string(item.method.wireValue),
                "code": .string(state.code.rawValue),
                "filtered": .bool(state.isFiltered),
                "recoverable": .bool(state.isRecoverable)
            ]))
        }
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

    // MARK: Monitoring

    /// Exposed at `internal` access only so tests can `await` the monitoring install fired at
    /// construction (`CREATE`/`SET_SESSION`/`READY`) — a merchant has no need to touch it.
    private(set) var pendingMonitoringInstall: Task<Void, Never>?

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
        postMonitoring(.methodRegister, .info, monitoringPayload([
            "partner": .string(method.partner.wireValue),
            "method": .string(method.method.wireValue),
            "saveToken": .bool(registered)
        ]))
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
        postMonitoring(.secondaryTokenRegister, .info, monitoringPayload([
            "partner": .string(token.partner.wireValue),
            "method": .string(token.method.wireValue),
            "saveToken": .bool(registered)
        ]))
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
        await eventBus.post(.tokenEdit, .info, monitoringPayload([
            "partner": .string(token.partner.wireValue), "method": .string(token.method.wireValue), "tokenId": .string(token.id)
        ]))
    }

    /// Rename a saved gift card (`PATCH …/tokens/{id}/name`) — same rules as the card overload.
    public func editToken(_ token: SavedSecondaryToken, name: String) async throws {
        let client = try wallet.requireClient()
        try wallet.requireToken(token.id)
        try validateTokenLabel(name, excludingTokenId: token.id)
        try await client.editTokenName(token.id, name: name)
        updateSavedSecondary(token.id) { $0.name = name }
        await eventBus.post(.tokenEdit, .info, monitoringPayload([
            "partner": .string(token.partner.wireValue), "method": .string(token.method.wireValue), "tokenId": .string(token.id)
        ]))
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
        await eventBus.post(.tokenDelete, .info, monitoringPayload([
            "partner": .string(token.partner.wireValue), "method": .string(token.method.wireValue), "tokenId": .string(token.id)
        ]))
        refresh()
    }

    /// Toggle a saved card's favorite flag — web's `token.setAsFavorite()`: optimistic local
    /// update, reverted if the wallet call fails.
    public func setTokenFavorite(_ token: PaymentToken) async throws {
        let client = try wallet.requireClient()
        try wallet.requireToken(token.id)
        let newFavorite = !token.favorite
        updateTokenItem(token.id) { $0.favorite = newFavorite }
        await eventBus.post(.tokenSetFavorite, .info, monitoringPayload([
            "partner": .string(token.partner.wireValue),
            "method": .string(token.method.wireValue),
            "tokenId": .string(token.id),
            "favorite": .bool(newFavorite)
        ]))
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
        await eventBus.post(.deleteAllTokens)
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

    // MARK: Badges

    /// The CDN badge for one item, resolved for this session's environment.
    ///
    /// Returns a URL string; loading and rendering it is yours. The SDK ships no images.
    public func iconURL(for item: PaymentItem) -> String {
        PurseAssets.resolveIconURL(
            partner: item.partner,
            method: item.method,
            isSecondary: item.isSecondary,
            environment: environment
        )
    }

    /// The card-scheme badges a method accepts, for the row that offers it. A brand with no badge
    /// is left out rather than pointed at a URL that would 404.
    public func schemeAssets(for method: PrimaryMethod) -> [PurseAssets.CardSchemeAsset] {
        PurseAssets.buildCardSchemeAssets(brands: method.supportedBrands, environment: environment)
    }

    // MARK: Confirming the payment

    /// Every transaction so far, raw. Prefer ``paymentStatus()`` unless you need untouched rows.
    ///
    /// Uses the **same** session id as `/init` and `/validate` — `payment_session.id`, not
    /// `legacy_payment_session_id`, which belongs to a different service's key space.
    public func sessionTransactions() async throws -> [JSONValue] {
        try await api.getSession()
    }

    /// What the session's transactions say about the payment, right now.
    ///
    /// This is the answer ``PaymentOutcome/returnedFromRedirect(url:)`` is not: a shopper returning
    /// from a 3-D Secure or PSP page tells you they came back, nothing more. Ask the session.
    public func paymentStatus() async throws -> PaymentSessionStatus {
        PaymentSessionStatus.from(try await sessionTransactions())
    }

    /// Poll ``paymentStatus()`` until it settles, or until `timeout` elapses.
    ///
    /// Returns the last status on timeout, and on cancellation once it holds one — a caller that has
    /// just taken a shopper's money needs something to show them. Cancelling before the first status
    /// arrives throws `CancellationError`, never the transport error underneath it, which would read
    /// as a network failure. A genuine transport or teardown failure still throws. Defaults match
    /// Android's 60 s / 3 s.
    public func awaitPaymentOutcome(
        timeout: Duration = .seconds(60),
        pollInterval: Duration = .seconds(3)
    ) async throws -> PaymentSessionStatus {
        let deadline = ContinuousClock.now + timeout
        var latest: PaymentSessionStatus
        do {
            latest = try await paymentStatus()
        } catch {
            // Cancelled before any status arrived: there is nothing to report, but the caller must
            // still not be handed a transport error that reads as a network failure.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        while case .pending = latest, ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: pollInterval)
                latest = try await paymentStatus()
            } catch {
                // Cancelled mid-poll — the caller's screen went away. Hand back what is known
                // rather than throwing at someone who has just taken a shopper's money. The sleep
                // raises `CancellationError` but `URLSession` raises a transport error, so the
                // task's own flag is the only signal that covers both.
                if Task.isCancelled { return latest }
                throw error
            }
        }
        return latest
    }

    // MARK: Loan simulation

    /// One BNPL instalment schedule for `method` at `product`'s amount — gated on the method's own
    /// `simulable` label (`configuration.labels.contains("simulable")`).
    public func simulateLoan(_ method: PrimaryMethod, product: LoanProduct) async throws -> LoanSimulation {
        guard method.simulable else { throw PurseCheckoutError.methodNotSimulable(itemId: method.id) }
        await eventBus.post(.methodLoanSim, .info, monitoringPayload([
            "partner": .string(method.partner.wireValue),
            "method": .string(method.method.wireValue),
            "currencyCode": .string(product.currencyCode)
        ]))
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
        await eventBus.post(.methodLoanSim, .info, monitoringPayload([
            "partner": .string(method.partner.wireValue),
            "method": .string(method.method.wireValue),
            "currencyCode": .string(product.currencyCode)
        ]))
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

    /// Snapshot this checkout for `restore` after process death: the session blob, the primary
    /// selection, the applied gift cards and slices, the save decisions and what was collected.
    /// Never card data.
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
        urlSession: URLSession = .shared,
        options: PluginOptions = PluginOptions()
    ) throws -> PurseHeadlessCheckout {
        let checkout = try PurseHeadlessCheckout(
            widgetData: state.widgetData,
            lockedEnvironment: state.lockedEnvironment,
            disabledMethods: state.disabledMethods,
            hooks: hooks,
            registry: registry,
            secondaryConfigs: secondaryConfigs,
            instanceId: state.instanceId,
            urlSession: urlSession,
            options: options
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
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
            self.backgroundObserver = nil
        }
        // Otherwise it keeps waking every five seconds for the life of the process. It holds `self`
        // weakly so it would end on deallocation anyway, but a merchant who tears down and keeps
        // the object around is exactly who called this.
        expiryWatchdog?.cancel()
        for task in pendingSessionSet.values { task.cancel() }
        pendingSessionSet.removeAll()
        trackedPlugins.removeAll()
        Task {
            await eventBus.post(.pageUnload)
            await eventBus.flush()
        }
    }
}
