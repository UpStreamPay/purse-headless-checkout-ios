// Web: navigator.userAgent + screen, sent on HEADLESS_CHECKOUT_CREATE.
// Same: purpose — what RUN parses out of a web user agent, native platforms send directly.
// Differs: `UIDevice`/`UIScreen` instead of `Build`/`DisplayMetrics`.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum CheckoutMonitoringContext {
    /// What a native vault SDK's own logger already sends as a user agent — there is no
    /// `navigator.userAgent` on iOS, so this is deliberately terse, not a browser-shaped string.
    @MainActor
    static func userAgent() -> String {
        #if canImport(UIKit)
        let device = UIDevice.current
        return "\(device.systemName)/\(device.systemVersion) (\(device.model))"
        #else
        return "ios"
        #endif
    }

    /// Device context for `HEADLESS_CHECKOUT_CREATE` — Android's `device{…}` block (OS version,
    /// manufacturer, model). Every field is optional so a non-UIKit target (a future watchOS/macOS
    /// host, say) simply yields less rather than failing to build.
    @MainActor
    static func deviceContext() -> JSONValue {
        #if canImport(UIKit)
        let device = UIDevice.current
        return monitoringPayload([
            "os": .string("ios"),
            "os_version": .string(device.systemVersion),
            "manufacturer": .string("Apple"),
            "model": .string(device.model)
        ])
        #else
        return monitoringPayload(["os": .string("ios")])
        #endif
    }

    /// Web's `screen` payload (`width`, `height`, `devicePixelRatio`).
    @MainActor
    static func screen() -> JSONValue {
        #if canImport(UIKit)
        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        return monitoringPayload([
            "width": .number(String(Int(bounds.width * scale))),
            "height": .number(String(Int(bounds.height * scale))),
            "devicePixelRatio": .number(scale.description)
        ])
        #else
        return .object([:])
        #endif
    }
}
