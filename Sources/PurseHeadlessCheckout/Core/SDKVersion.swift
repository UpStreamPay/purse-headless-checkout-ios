// The version release-please stamps when it cuts a release — the annotation on the line below is
// what it looks for. A working tree between releases carries the last released value.

import Foundation

/// The SDK version this app was built against, stamped on every monitoring event.
public enum SDKVersion {
    public static let value = "0.0.0" // x-release-please-version
}
