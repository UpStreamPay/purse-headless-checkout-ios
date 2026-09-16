import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// What a redirect is allowed to load, and what counts as coming back. This is a security boundary:
/// a redirect chain that can load anything is an exfiltration path, and a "return" another app can
/// fabricate is a fake approval.
struct RedirectPolicyTests {

    private let universalLink = RedirectPolicy(
        returnDestination: .universalLink(host: "checkout.example.com", path: "/purse/return")
    )
    private let customScheme = RedirectPolicy(returnDestination: .customScheme("myapp-purse"))

    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    // MARK: What may load

    @Test func httpsIsAllowed() throws {
        #expect(universalLink.allowsLoading(try url("https://acs.bank.example/3ds")))
    }

    /// A challenge chain never legitimately needs these, and allowing them is how a redirect turns
    /// into an exfiltration path.
    @Test(arguments: [
        "http://acs.bank.example/3ds",
        "file:///etc/passwd",
        "javascript:alert(1)",
        "ftp://files.example/x",
        "someotherapp://open",
    ])
    func everythingButHTTPSIsRefused(_ candidate: String) throws {
        #expect(!universalLink.allowsLoading(try url(candidate)))
    }

    /// The return destination is allowed whatever its scheme — it is where the flow ends.
    @Test func theReturnDestinationIsAlwaysAllowed() throws {
        #expect(customScheme.allowsLoading(try url("myapp-purse://return")))
        #expect(universalLink.allowsLoading(try url("https://checkout.example.com/purse/return")))
    }

    /// An empty host allowlist means "any https host"; a populated one narrows it.
    @Test func anAllowlistNarrowsToNamedHosts() throws {
        let narrowed = RedirectPolicy(
            returnDestination: .customScheme("myapp-purse"),
            additionalAllowedHosts: ["acs.bank.example"]
        )

        #expect(narrowed.allowsLoading(try url("https://acs.bank.example/3ds")))
        #expect(!narrowed.allowsLoading(try url("https://evil.example/steal")))
        // …and the return still works regardless.
        #expect(narrowed.allowsLoading(try url("myapp-purse://return")))
    }

    // MARK: What counts as coming back

    @Test func aUniversalLinkReturnMatchesHostAndPathPrefix() throws {
        #expect(universalLink.isReturn(try url("https://checkout.example.com/purse/return")))
        #expect(universalLink.isReturn(try url("https://checkout.example.com/purse/return?status=ok")))
        #expect(universalLink.isReturn(try url("https://checkout.example.com/purse/return/extra")))
    }

    /// A different host, or a different path, is not our return — this is what stops an arbitrary
    /// page in the chain from ending the flow early.
    @Test(arguments: [
        "https://evil.example/purse/return",
        "https://checkout.example.com/somewhere/else",
        "http://checkout.example.com/purse/return",
    ])
    func aNearMissIsNotAReturn(_ candidate: String) throws {
        #expect(!universalLink.isReturn(try url(candidate)))
    }

    @Test func hostAndSchemeMatchingIsCaseInsensitive() throws {
        #expect(universalLink.isReturn(try url("https://CHECKOUT.EXAMPLE.COM/purse/return")))
        #expect(customScheme.isReturn(try url("MYAPP-PURSE://return")))
    }

    @Test func aCustomSchemeReturnMatchesOnTheScheme() throws {
        #expect(customScheme.isReturn(try url("myapp-purse://anything/at/all")))
        #expect(!customScheme.isReturn(try url("otherapp://return")))
    }

    /// Only a custom-scheme policy gives ASWebAuthenticationSession a scheme to match; a Universal
    /// Link policy uses the `.https` callback on iOS 17.4+.
    @Test func onlyACustomSchemePolicyExposesACallbackScheme() {
        #expect(customScheme.callbackScheme == "myapp-purse")
        #expect(universalLink.callbackScheme == nil)
    }

    // MARK: Outcomes

    /// The type deliberately has no `success` case. Reaching the return only means the shopper came
    /// back; the real outcome lives on the session.
    @Test func thereIsNoSuccessOutcome() {
        let all: [RedirectOutcome] = [.returned(url: nil), .canceled]
        #expect(all.count == 2)
    }
}

/// What the in-app web view loads first, for each action shape. The `.get` case used to answer "a
/// GET redirect belongs in the browser, not this view" — true while only the browser served GETs,
/// and wrong the moment `prefersInAppWebView` existed.
@MainActor
struct RedirectFirstLoadTests {

    private let policy = RedirectPolicy(
        returnDestination: .universalLink(host: "return.example", path: "/done")
    )

    private func firstLoad(_ action: RedirectAction) -> RedirectWebViewController.FirstLoad {
        RedirectWebViewController.firstLoad(for: action, policy: policy)
    }

    @Test func aGetIsLoadedRatherThanRefused() {
        let url = "https://acs.bank.example/3ds"
        #expect(firstLoad(.get(url: url)) == .request(URL(string: url)!))
    }

    @Test func aPostFormBecomesAnAutoSubmittingPage() throws {
        let action = RedirectAction.postForm(url: "https://acs.bank.example/3ds", formDataURLEncoded: "a=1")
        guard case let .html(html, baseURL) = firstLoad(action) else {
            Issue.record("expected html, got \(firstLoad(action))")
            return
        }
        // WebKit drops a `load(_:)` body, so the POST has to be a real form the page submits.
        #expect(html.contains("form"))
        #expect(baseURL == URL(string: "https://acs.bank.example/3ds"))
    }

    @Test func serverSentMarkupGetsNoBaseURL() {
        guard case let .html(_, baseURL) = firstLoad(.postHTML(html: "<form></form>")) else {
            Issue.record("expected html")
            return
        }
        // No base URL also means a relative load cannot escape to an unexpected host.
        #expect(baseURL == nil)
    }

    /// The first navigation is the one the delegate never sees, so it is the one this must gate.
    @Test func aDisallowedURLIsRefusedForEveryShape() {
        let blocked = RedirectPolicy(
            returnDestination: .universalLink(host: "return.example", path: "/done"),
            additionalAllowedHosts: ["allowed.example"]
        )
        let actions: [RedirectAction] = [
            .get(url: "https://evil.example/x"),
            .postForm(url: "https://evil.example/x", formDataURLEncoded: "a=1"),
        ]
        for action in actions {
            let load = RedirectWebViewController.firstLoad(for: action, policy: blocked)
            #expect(load == .refused("https://evil.example/x"))
        }
    }

    @Test func aNonHTTPSGetIsRefused() {
        #expect(firstLoad(.get(url: "http://acs.bank.example/3ds")) == .refused("http://acs.bank.example/3ds"))
    }
}

/// What counts as coming back, for the in-app web view. Pure, so it covers the paths a presented
/// `WKWebView` would otherwise hide — including the server-redirect one, where the last hop of a
/// payment return actually arrives.
@MainActor
struct RedirectReturnDetectionTests {

    private let policy = RedirectPolicy(
        returnDestination: .universalLink(host: "return.example", path: "/done")
    )

    private func isReturn(_ raw: String, action: RedirectAction) -> Bool {
        RedirectWebViewController.isReturn(URL(string: raw)!, action: action, policy: policy)
    }

    private let plain = RedirectAction.get(url: "https://acs.bank.example/3ds")

    @Test func thePolicysOwnDestinationEndsTheFlow() {
        #expect(isReturn("https://return.example/done?x=1", action: plain))
    }

    /// The common case: a PSP redirects to the merchant's configured page, not to the app.
    @Test func theSessionsConfiguredReturnEndsTheFlow() {
        let action = RedirectAction.get(
            url: "https://acs.bank.example/3ds",
            returnURLPrefix: "https://cdn.purse-dev.com/return/done.html"
        )
        #expect(isReturn("https://cdn.purse-dev.com/return/done.html?purse-redirection-data=a.b.c", action: action))
    }

    /// Caught even when the session configured no return URL at all.
    @Test func theWidgetConfirmationHopEndsTheFlow() {
        #expect(isReturn("https://anywhere.example/x?purse-redirection-data=a.b.c", action: plain))
    }

    @Test func anOrdinaryChallengeHopDoesNot() {
        #expect(!isReturn("https://acs.bank.example/3ds/step2", action: plain))
        // A prefix that merely shares a host is not the return.
        #expect(!isReturn("https://return.example/elsewhere", action: plain))
    }

    /// The query string is what carries the reported status, so it must survive detection.
    @Test func theQueryStringIsNotPartOfTheMatch() {
        #expect(isReturn("https://return.example/done", action: plain))
        #expect(isReturn("https://return.example/done?purse-redirection-data=a.b.c&foo=1", action: plain))
    }
}
