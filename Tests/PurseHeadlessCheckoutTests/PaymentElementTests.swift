import Foundation
import SwiftUI
import Testing
@testable import PurseHeadlessCheckout

/// The payment element: what it resolves to, and the one outcome each attempt produces. Its own
/// host and session id — `StubURLProtocol` keys handlers by host and `InitGuard.shared` is process-
/// wide, so a suite sharing either with another would read the other's answers.
@MainActor
@Suite(.serialized)
struct PaymentElementTests {

    private static let host = "api.purse-element.example"

    private struct StubPlugin: PartnerUIPlugin {
        let partner: Partner
        let method: PaymentMethod
        func preValidation(_ context: PartnerUIContext) async throws -> ValidateItemPayload {
            ItemPayload(partner: partner, method: method, amount: context.amount)
        }
    }

    /// Renders nothing and captures straight away — enough to drive `ElementFlow` without a vault.
    private struct StubModule: PartnerModule {
        let id = "test.element"
        @MainActor func register(into registry: PluginRegistry) {
            registry.registerVault(vendor: .purse) { StubPlugin(partner: $0.partner, method: $0.method) }
        }

        @MainActor func renders(_ plugin: any PartnerUIPlugin) -> Bool { plugin is StubPlugin }

        @MainActor func surface(for plugin: any PartnerUIPlugin, request: SurfaceRequest) -> PaymentSurface? {
            .headless(
                prepare: { request.listener.onReady(true) },
                submit: { await request.captureNow() }
            )
        }
    }

    private final class Spy: PaymentElementListener {
        var outcomes: [PaymentOutcome] = []
        var readies: [Bool] = []
        var paymentIds: [String] = []
        var requiresAction = 0

        func onReady(_ ready: Bool) { readies.append(ready) }
        func onOutcome(_ outcome: PaymentOutcome) { outcomes.append(outcome) }
        func onRequiresAction() { requiresAction += 1 }
        func onPaymentId(_ paymentId: String) { paymentIds.append(paymentId) }
    }

    private final class SpyPresenter: RedirectPresenter {
        var presented: [RedirectAction] = []
        var answer: RedirectOutcome = .returned(url: nil)
        func present(_ action: RedirectAction) async throws -> RedirectOutcome {
            presented.append(action)
            return answer
        }
    }

    /// `empty` drops even the built-in card and redirection modules, so nothing renders.
    private func makeCheckout(empty: Bool = false) throws -> PurseHeadlessCheckout {
        let registry = PluginRegistry()
        registry.reset()
        if !empty { registry.install(StubModule()) }
        return try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(
                apiURL: "https://\(Self.host)/payment/v1",
                paymentSession: TestSessions.paymentSession(id: "payment-element-session", amount: 100)
            ),
            registry: registry,
            urlSession: StubURLProtocol.session()
        )
    }

    private func cardItem(_ checkout: PurseHeadlessCheckout) throws -> PaymentItem {
        try #require(checkout.paymentMethods.first { $0.id == "purse-creditcard" })
    }

    /// Selecting is the host's job, never the element's — so every flow test does it first, exactly
    /// as a screen would.
    @discardableResult
    private func selectCard(_ checkout: PurseHeadlessCheckout) throws -> PaymentItem {
        let item = try cardItem(checkout)
        guard case let .primaryMethod(method) = item else {
            Issue.record("the session's card is not a primary method")
            return item
        }
        try checkout.setPrimary(method)
        return item
    }

    private func stubValidate(_ body: String) {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/validate", .ok(body), host: Self.host)
    }

    private static let success = #"{"global_status":"SUCCESS","results":[]}"#
    private static let withRedirect =
        #"{"global_status":"WAITING","results":[],"redirection":{"url":"https://acs.bank.example/3ds"}}"#

    // MARK: Resolution

    /// `host(for:)` takes a `PrimarySource`, and a secondary is not one — a branch Android has no
    /// peer for, because Kotlin lets it fail at runtime instead.
    @Test func aSecondaryItemRefusesInsteadOfRendering() async throws {
        stubValidate(Self.success)
        let checkout = try makeCheckout()
        let spy = Spy()
        // Reuse the session's own card configuration; only the case matters here.
        let card = try cardItem(checkout)
        let secondary = PaymentItem.secondaryMethod(SecondaryMethod(
            id: "illicado-giftcard",
            partner: .illicado,
            method: .giftCard,
            configuration: card.configuration
        ))

        let element = checkout.paymentElement(for: secondary, listener: spy)
        #expect(element.hasUI == false)
        await element.submit().value

        guard case let .failed(error) = try #require(spy.outcomes.first) else {
            Issue.record("expected a failure, got \(spy.outcomes)")
            return
        }
        #expect(error.message.contains("applySecondary"))
        #expect(StubURLProtocol.paths(host: Self.host).isEmpty)
    }

    @Test func aTechnicallyDisabledItemReportsWhyItIsDisabled() async throws {
        stubValidate(Self.success)
        let checkout = try makeCheckout()
        let spy = Spy()
        let disabled = try cardItem(checkout).withDisabled(.tokenInitFailed)

        let element = checkout.paymentElement(for: disabled, listener: spy)
        #expect(element.hasUI == false)
        await element.submit().value

        guard case let .failed(error) = try #require(spy.outcomes.first) else {
            Issue.record("expected a failure, got \(spy.outcomes)")
            return
        }
        #expect(error.code == .methodDisabled)
        #expect(StubURLProtocol.paths(host: Self.host).isEmpty)
    }

    @Test func anItemWithNoRegisteredPluginReportsThatRatherThanRendering() async throws {
        stubValidate(Self.success)
        let checkout = try makeCheckout(empty: true)
        let spy = Spy()

        let element = checkout.paymentElement(for: try cardItem(checkout), listener: spy)
        #expect(element.hasUI == false)
        await element.submit().value

        guard case let .failed(error) = try #require(spy.outcomes.first) else {
            Issue.record("expected a failure, got \(spy.outcomes)")
            return
        }
        #expect(error.code == .methodNotImplemented)
    }

    // MARK: The flow

    @Test func aHeadlessElementCompletesWithTheAPIVerdict() async throws {
        stubValidate(Self.success)
        let checkout = try makeCheckout()
        let spy = Spy()

        let element = checkout.paymentElement(for: try selectCard(checkout), listener: spy)
        await element.prepare()
        #expect(element.isReady)
        #expect(spy.readies == [true])

        await element.submit().value

        guard case let .completed(result) = try #require(spy.outcomes.first) else {
            Issue.record("expected a completion, got \(spy.outcomes)")
            return
        }
        #expect(result.isSuccess)
        #expect(spy.requiresAction == 0)
    }

    /// The return URL reaches the listener, so a host can read what the redirect reported without
    /// a round trip to its own backend.
    @Test func theReturnURLReachesTheListener() async throws {
        stubValidate(Self.withRedirect)
        let checkout = try makeCheckout()
        let spy = Spy()
        let presenter = SpyPresenter()
        let returned = "https://shop.example/return?purse-redirection-data=h.\(Self.claims).s"
        presenter.answer = .returned(url: URL(string: returned))

        let element = checkout.paymentElement(for: try selectCard(checkout), listener: spy, redirect: presenter)
        await element.submit().value

        guard case let .returnedFromRedirect(url) = try #require(spy.outcomes.first) else {
            Issue.record("expected a redirect return, got \(spy.outcomes)")
            return
        }
        let data = try #require(url?.absoluteString.widgetRedirectionData)
        #expect(data.paymentId == "pay_777")
        #expect(data.isAuthorized)
    }

    private static let claims: String = {
        Data(#"{"payment_id":"pay_777","authorization_status":"AUTHORIZED"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }()

    @Test func aRedirectingValidateAnnouncesTheActionThenReportsTheReturn() async throws {
        stubValidate(Self.withRedirect)
        let checkout = try makeCheckout()
        let spy = Spy()
        let presenter = SpyPresenter()

        let element = checkout.paymentElement(for: try selectCard(checkout), listener: spy, redirect: presenter)
        await element.submit().value

        #expect(spy.requiresAction == 1)
        #expect(presenter.presented == [.get(url: "https://acs.bank.example/3ds")])
        guard case .returnedFromRedirect = try #require(spy.outcomes.first) else {
            Issue.record("a redirect return is never a completion — got \(spy.outcomes)")
            return
        }
        // And explicitly not a success: the final redirect is built server-side.
        #expect(spy.outcomes.first?.isSuccess == false)
    }

    @Test func aDismissedRedirectIsACancel() async throws {
        stubValidate(Self.withRedirect)
        let checkout = try makeCheckout()
        let spy = Spy()
        let presenter = SpyPresenter()
        presenter.answer = .canceled

        let element = checkout.paymentElement(for: try selectCard(checkout), listener: spy, redirect: presenter)
        await element.submit().value

        guard case .canceled = try #require(spy.outcomes.first) else {
            Issue.record("expected a cancel, got \(spy.outcomes)")
            return
        }
    }

    /// With no presenter the redirect is the caller's to follow, so the API's answer is the outcome
    /// — not a failure, and nothing is opened.
    @Test func aRedirectWithNoPresenterCompletesAndOpensNothing() async throws {
        stubValidate(Self.withRedirect)
        let checkout = try makeCheckout()
        let spy = Spy()

        let element = checkout.paymentElement(for: try selectCard(checkout), listener: spy)
        await element.submit().value

        guard case .completed = try #require(spy.outcomes.first) else {
            Issue.record("expected a completion, got \(spy.outcomes)")
            return
        }
        #expect(spy.requiresAction == 0)
    }

    @Test func thePaymentIdIsReadFromTheWidgetConfirmationJWT() async throws {
        // `{"payment_id":"pay_123"}` as an unpadded base64url JWT payload.
        let payload = Data(#"{"payment_id":"pay_123"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let url = "https://shop.example/return?purse-redirection-data=header.\(payload).signature"
        stubValidate(#"{"global_status":"SUCCESS","results":[],"redirection":{"url":"\#(url)"}}"#)

        let checkout = try makeCheckout()
        let spy = Spy()
        let element = checkout.paymentElement(for: try selectCard(checkout), listener: spy)
        await element.submit().value

        #expect(spy.paymentIds == ["pay_123"])
    }

    // MARK: Re-entrancy

    /// Two taps in the same turn, the way a double tap on a wallet button arrives — not two
    /// sequential `await`s, which serialise and would pass against the bug.
    @Test func aDoubleTapPostsValidateOnce() async throws {
        stubValidate(Self.success)
        let checkout = try makeCheckout()
        let spy = Spy()

        let element = checkout.paymentElement(for: try selectCard(checkout), listener: spy)
        let first = element.submit()
        let second = element.submit()
        await first.value
        await second.value

        #expect(StubURLProtocol.paths(host: Self.host).filter { $0.hasSuffix("/validate") }.count == 1)
        #expect(spy.outcomes.count == 1)
    }
}

/// The height rule behind `PaymentElementView.sizeThatFits`. Extracted because a
/// `UIViewRepresentableContext` cannot be built in a test, so the branch is tested on its own.
@Suite
struct PaymentElementSizingTests {

    /// Apple Pay and PayPal have different intrinsic heights; an express row that stacks both needs
    /// one height, and asking for it must win over either.
    @Test func anExplicitHeightIsHonoured() {
        #expect(PaymentElementView.explicitHeight(ProposedViewSize(width: 320, height: 48)) == 48)
    }

    /// "Size yourself" in its three spellings. Each must fall through to the partner view's own
    /// height — returning 0 or infinity here would collapse or explode the row.
    @Test func anUnspecifiedHeightFallsBackToTheIntrinsicOne() {
        #expect(PaymentElementView.explicitHeight(ProposedViewSize(width: 320, height: nil)) == nil)
        #expect(PaymentElementView.explicitHeight(ProposedViewSize(width: 320, height: .infinity)) == nil)
        #expect(PaymentElementView.explicitHeight(ProposedViewSize(width: 320, height: 0)) == nil)
        #expect(PaymentElementView.explicitHeight(.unspecified) == nil)
    }
}
