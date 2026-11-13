import Foundation

/// A tiny JSON reader for alfred's merchant-backend responses; the SDK's `JSONValue` covers
/// payment-session shapes only.
@dynamicMemberLookup
struct DemoJSON {
    let raw: Any

    init(_ data: Data) throws {
        raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    init(raw: Any) { self.raw = raw }

    static func object(_ fields: [String: DemoJSON]) -> DemoJSON {
        DemoJSON(raw: fields.mapValues(\.raw))
    }

    static func number(_ value: Double) -> DemoJSON { DemoJSON(raw: value) }

    subscript(key: String) -> DemoJSON? {
        guard let dictionary = raw as? [String: Any], let value = dictionary[key] else { return nil }
        return DemoJSON(raw: value)
    }

    subscript(dynamicMember key: String) -> DemoJSON? { self[key] }

    var string: String? { raw as? String }
    var array: [DemoJSON]? { (raw as? [Any])?.map(DemoJSON.init(raw:)) }
    var rawObject: Any { raw }

    var pretty: String {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        else { return String(describing: raw) }
        return String(decoding: data, as: UTF8.self)
    }

    var compact: String { String(describing: raw).prefix(200).description }
}
