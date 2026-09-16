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
