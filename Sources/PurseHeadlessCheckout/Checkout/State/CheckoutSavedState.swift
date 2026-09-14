// Web: none — a browser tab keeps the SDK alive; iOS may suspend or kill the process while the shopper is in a bank app, PayPal or a 3-D Secure page.
// Same: n/a.
// Differs: the checkout's choices (primary, applied gift cards, save decisions, what the native steps collected, whether a submit left) serialize to a small JSON the host stores and hands back to `PurseHeadlessCheckout.restore`.

import Foundation

/// A snapshot of a ``PurseHeadlessCheckout`` — everything needed to pick a payment up where the
/// shopper left it after the process was killed: the client session, the primary selection, the
/// applied gift cards and their slices, the save decisions, what the native steps collected,
public struct CheckoutSavedState: Sendable, Equatable {
    static let version = 1

    let widgetData: String
    let lockedEnvironment: PurseEnvironment?
    let disabledMethods: Set<MethodKey>
    let instanceId: String
    let primaryId: String?
    let secondaries: [(token: SecondaryToken, amount: Decimal)]
    let registrationByMethod: [String: RegistrationState]
    let registrationBySecondaryToken: [String: RegistrationState]
    let collectedByItem: [String: [String: JSONValue]]
    let submitted: Bool
    /// When the snapshot was taken.
    public let savedAt: Date

    /// Same-content snapshots compare equal — compared by their serialized form, since `secondaries`
    /// holds tuples, which cannot themselves conform to `Equatable`.
    public static func == (lhs: CheckoutSavedState, rhs: CheckoutSavedState) -> Bool {
        lhs.toJSON() == rhs.toJSON()
    }

    /// The snapshot as JSON text — the same string ``fromJSON(_:)`` accepts.
    public func toJSON() -> String {
        var secondariesArray: [JSONValue] = []
        for (token, amount) in secondaries {
            secondariesArray.append(.object([
                "id": .string(token.id),
                "partner": .string(token.partner.wireValue),
                "method": .string(token.method.wireValue),
                "pan": .string(token.pan),
                "cvv": token.cvv.map(JSONValue.string) ?? .null,
                "name": .string(token.name),
                "balance": .number(token.balance.description),
                "totalBalance": .number(token.totalBalance.description),
                "expirationDate": .string(token.expirationDate),
                "takePolicy": .string(token.takePolicy.rawValue),
                "limit": token.limit.map { .number($0.description) } ?? .null,
                "usageLimit": token.usageLimit.map { .number(String($0)) } ?? .null,
                "saveTokenMode": .string(token.saveTokenMode.rawValue),
                "isSaved": .bool(token.isSaved),
                "amount": .number(amount.description)
            ]))
        }

        let object = JSONValue.object([
            "version": .number(String(Self.version)),
            "widgetData": .string(widgetData),
            "lockedEnvironment": lockedEnvironment.map { .string($0.wireValue) } ?? .null,
            "disabledMethods": .array(disabledMethods.map {
                .object(["partner": .string($0.partner.wireValue), "method": .string($0.method.wireValue)])
            }),
            "instanceId": .string(instanceId),
            "primaryId": primaryId.map(JSONValue.string) ?? .null,
            "secondaries": .array(secondariesArray),
            "registrationByMethod": .object(registrationByMethod.mapValues { $0.toJSON() }),
            "registrationBySecondaryToken": .object(registrationBySecondaryToken.mapValues { $0.toJSON() }),
            "collected": .object(collectedByItem.mapValues { .object($0) }),
            "submitted": .bool(submitted),
            "savedAt": .number(String(savedAt.timeIntervalSince1970))
        ])

        return (try? JSONEncoder().encode(object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Parse a snapshot ``toJSON()`` produced.
    public static func fromJSON(_ json: String) throws -> CheckoutSavedState {
        guard let data = json.data(using: .utf8),
              let object = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            throw PurseSessionError.sessionMalformed("CheckoutSavedState is not valid JSON")
        }
        let version = object["version"]?.intValue ?? -1
        guard (1...Self.version).contains(version) else {
            throw PurseSessionError.sessionMalformed("unsupported CheckoutSavedState version \(version)")
        }
        guard let widgetData = object["widgetData"]?.stringValue else {
            throw PurseSessionError.sessionMalformed("CheckoutSavedState carries no session")
        }

        let disabledMethods = Set((object["disabledMethods"]?.arrayValue ?? []).compactMap { entry -> MethodKey? in
            guard let partner = entry["partner"]?.stringValue, let method = entry["method"]?.stringValue else { return nil }
            return MethodKey.of(partner: partner, method: method)
        })

        let secondaries: [(token: SecondaryToken, amount: Decimal)] = (object["secondaries"]?.arrayValue ?? [])
            .compactMap(Self.secondaryToken(from:))

        let registrationByMethod = (object["registrationByMethod"]?.objectValue ?? [:]).compactMapValues(RegistrationState.init(json:))
        let registrationBySecondaryToken = (object["registrationBySecondaryToken"]?.objectValue ?? [:])
            .compactMapValues(RegistrationState.init(json:))
        let collectedByItem = (object["collected"]?.objectValue ?? [:]).compactMapValues { $0.objectValue }

        return CheckoutSavedState(
            widgetData: widgetData,
            lockedEnvironment: PurseEnvironment.fromWire(object["lockedEnvironment"]?.stringValue),
            disabledMethods: disabledMethods,
            instanceId: object["instanceId"]?.stringValue ?? UUID().uuidString,
            primaryId: object["primaryId"]?.stringValue,
            secondaries: secondaries,
            registrationByMethod: registrationByMethod,
            registrationBySecondaryToken: registrationBySecondaryToken,
            collectedByItem: collectedByItem,
            submitted: object["submitted"]?.boolValue ?? false,
            savedAt: object["savedAt"]?.decimalValue.map { Date(timeIntervalSince1970: NSDecimalNumber(decimal: $0).doubleValue) } ?? Date()
        )
    }

    private static func secondaryToken(from json: JSONValue) -> (token: SecondaryToken, amount: Decimal)? {
        guard let id = json["id"]?.stringValue,
              let partner = json["partner"]?.stringValue,
              let method = json["method"]?.stringValue,
              let pan = json["pan"]?.stringValue,
              let amount = json["amount"]?.asDecimal
        else { return nil }

        let token = SecondaryToken(
            id: id,
            partner: Partner.fromWire(partner),
            method: PaymentMethod.fromWire(method),
            pan: pan,
            cvv: json["cvv"]?.stringValue,
            name: json["name"]?.stringValue ?? "",
            balance: json["balance"]?.asDecimal ?? 0,
            totalBalance: json["totalBalance"]?.asDecimal,
            expirationDate: json["expirationDate"]?.stringValue ?? "",
            takePolicy: json["takePolicy"]?.stringValue.flatMap(SecondaryTakePolicy.init(rawValue:)) ?? .none,
            limit: json["limit"]?.asDecimal,
            usageLimit: json["usageLimit"]?.intValue,
            saveTokenMode: json["saveTokenMode"]?.stringValue.flatMap(SaveTokenMode.init(rawValue:)) ?? .never,
            isSaved: json["isSaved"]?.boolValue ?? false
        )
        return (token, amount)
    }
}

extension RegistrationState {
    fileprivate func toJSON() -> JSONValue {
        .object(["registered": .bool(registered), "name": name.map(JSONValue.string) ?? .null])
    }

    fileprivate init?(json: JSONValue) {
        guard let registered = json["registered"]?.boolValue else { return nil }
        self.init(registered: registered, name: json["name"]?.stringValue)
    }
}
