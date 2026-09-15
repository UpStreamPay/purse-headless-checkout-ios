// Web: `manageRedirection` POST-form case (`packages/common/src/Redirection.ts`, `submitRedirectionForm`)
// Same: an auto-submitting hidden form carrying the PSP's fields.
// Differs: rendered into a `WKWebView` as HTML, for the reason in the doc below.

import Foundation

/// Builds the auto-submitting `<form>` a POST redirect is actually delivered through.
enum FormRedirectHTML {

    static func autoSubmitting(actionURL: String, dataString: String) -> String {
        let inputs = parseFormFields(dataString)
            .map { name, value in
                "<input type=\"hidden\" name=\"\(escaped(name))\" value=\"\(escaped(value))\">"
            }
            .joined(separator: "\n")

        return """
        <html><body onload="document.forms[0].submit()">
        <form method="POST" action="\(escaped(actionURL))">
        \(inputs)
        </form>
        </body></html>
        """
    }

    /// JSON first, falling back to a url-encoded query string — the PSP sends either. One level of
    /// nesting is flattened to `key[subKey]`, mirroring web's handling; a PSP that nests deeper
    /// would need the same treatment there first.
    static func parseFormFields(_ dataString: String) -> [(name: String, value: String)] {
        if let data = dataString.data(using: .utf8),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data),
           let object = json.objectValue {
            return object.keys.sorted().flatMap { key -> [(name: String, value: String)] in
                guard let value = object[key] else { return [] }
                if let nested = value.objectValue {
                    return nested.keys.sorted().compactMap { subKey in
                        nested[subKey].map { (name: "\(key)[\(subKey)]", value: $0.formFieldText) }
                    }
                }
                return [(name: key, value: value.formFieldText)]
            }
        }

        return dataString.split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = parts.first, !rawName.isEmpty else { return nil }
            let rawValue = parts.count > 1 ? String(parts[1]) : ""
            return (name: decoded(String(rawName)), value: decoded(rawValue))
        }
    }

    /// `+` is a space in `application/x-www-form-urlencoded`, which `removingPercentEncoding` alone
    /// does not know.
    private static func decoded(_ text: String) -> String {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private extension JSONValue {
    /// A field value as the PSP expects to receive it: the literal text for a scalar, and the
    /// re-encoded JSON for anything structured, matching Android's `value.toString()`.
    var formFieldText: String {
        switch self {
        case let .string(text): text
        case let .number(text): text
        case let .bool(value): value ? "true" : "false"
        case .null: ""
        case .array, .object:
            (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) as? String ?? ""
        }
    }
}
