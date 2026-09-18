// Web: packages/model /validate response
// Same: `global_status` + optional `redirection`.
// Differs: raw JSON kept for the redirect resolver.

import Foundation

/// The `/validate` response. ``raw`` is kept for whatever a plugin's `postValidation` inspects.
public struct ValidationResult: Sendable, Equatable {
    public let globalStatus: String
    public let redirection: Redirection?
    public let raw: JSONValue

    public init(globalStatus: String, redirection: Redirection?, raw: JSONValue) {
        self.globalStatus = globalStatus
        self.redirection = redirection
        self.raw = raw
    }

    public var status: PaymentStatus { .fromWire(globalStatus) }

    /// Web treats `global_status === SUCCESS` as the go-ahead for post-validation.
    public var isSuccess: Bool { status == .success }

    public struct Redirection: Sendable, Equatable {
        public let shouldSubmitWidget: Bool
        public let url: String?
        public let form: String?
        public let name: String?

        public init(shouldSubmitWidget: Bool, url: String?, form: String?, name: String?) {
            self.shouldSubmitWidget = shouldSubmitWidget
            self.url = url
            self.form = form
            self.name = name
        }
    }

    public static func fromJSON(_ json: JSONValue) -> ValidationResult {
        let redirection = json["redirection"].map { node in
            Redirection(
                shouldSubmitWidget: node["should_submit_widget"]?.boolValue ?? false,
                url: node["url"]?.stringValue?.nonBlank,
                form: node["form"]?.stringValue?.nonBlank,
                name: node["name"]?.stringValue?.nonBlank
            )
        }
        return ValidationResult(
            globalStatus: json["global_status"]?.stringValue ?? "",
            redirection: redirection,
            raw: json
        )
    }
}

extension String {
    /// `nil` when the string is empty or only whitespace — web's `takeIf(String::isNotBlank)`.
    var nonBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
