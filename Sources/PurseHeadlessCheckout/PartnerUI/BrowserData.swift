// Web: packages/partner-ui/src/plugins/utils/index.ts (`getBrowserData`)
// Same: the exact ten property names the Payment API accepts under `partner_data.browser`.
// Differs: native equivalents for what `window.navigator` would answer.

import Foundation
import UIKit

/// The `partner_data.browser` block a 3-D Secure step wants — the ACS uses it for challenge sizing
/// and locale.
public enum BrowserData {

    /// `@MainActor` for `UIScreen`. Every caller is an `async` plugin hook, so `await` costs nothing.
    @MainActor
    public static func make(locale: String?) -> [String: JSONValue] {
        let pixels = UIScreen.main.nativeBounds
        return [
            // No page URL on native; Android sends `android-app://{packageName}`.
            "referrer": .string("ios-app://\(Bundle.main.bundleIdentifier ?? "unknown")"),
            // No `navigator.userAgent`, and no WebView to ask synchronously. Android falls back to
            // the same constant when its WebView provider is unavailable.
            "user_agent": .string("MOBILE"),
            "accept_header": .string("text/html"),
            "color_depth": .number("32"),
            // Web hardcodes `true`; this means Java *applets*, which no native redirect runs.
            "java_enabled": .bool(false),
            "javascript_enabled": .bool(true),
            "locale": .string(locale?.nonBlank ?? Locale.preferredLanguages.first ?? "unknown"),
            "screen_height": .number(String(Int(pixels.height))),
            "screen_width": .number(String(Int(pixels.width))),
            // JavaScript's `getTimezoneOffset()` convention: **UTC − local**, in minutes, so a zone
            // ahead of UTC is negative (Paris in summer: -120).
            "utc_time_zone": .number(String(-TimeZone.current.secondsFromGMT() / 60)),
        ]
    }
}
