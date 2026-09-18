import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// `partner_data.browser`'s property names are a wire contract: the Payment API rejects the whole
/// `/init` with HTTP 400 on an unknown one, so an invented name breaks every affected method.
@MainActor
struct BrowserDataTests {

    /// Web's `getBrowserData` and Android's `RedirectionMapper.browserData` agree on these ten.
    private static let expected: Set<String> = [
        "referrer", "user_agent", "accept_header", "color_depth", "java_enabled",
        "javascript_enabled", "locale", "screen_height", "screen_width", "utc_time_zone",
    ]

    @Test func sendsExactlyThePropertyNamesTheAPIAccepts() {
        #expect(Set(BrowserData.make(locale: nil).keys) == Self.expected)
    }

    @Test func aMerchantLocaleWins() {
        #expect(BrowserData.make(locale: "fr-FR")["locale"]?.stringValue == "fr-FR")
        // Blank is not a choice — fall back rather than send an empty locale.
        #expect(BrowserData.make(locale: "  ")["locale"]?.stringValue != "  ")
    }

    /// JavaScript's `getTimezoneOffset()` convention: UTC − local in minutes, so a zone ahead of UTC
    /// is negative. Inverting this sends an ACS the wrong side of the world.
    @Test func theTimeZoneFollowsTheJavaScriptSignConvention() throws {
        let offset = try #require(BrowserData.make(locale: nil)["utc_time_zone"]?.intValue)
        #expect(offset == -TimeZone.current.secondsFromGMT() / 60)
    }
}
