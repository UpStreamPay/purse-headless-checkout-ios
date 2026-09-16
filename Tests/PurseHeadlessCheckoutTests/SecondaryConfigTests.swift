import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// The per-issuer rules. Each one is a real format a shopper types, so a wrong regex means a valid
/// card is rejected at the form — the kind of bug that only shows up in production.
@MainActor
struct SecondaryConfigTests {

    // MARK: Illicado

    @Test(arguments: ["9250004781234567890", "9250004101234567890"])
    func illicadoAcceptsItsOwnPrefixes(_ pan: String) {
        #expect(IllicadoConfig().validatePAN(pan))
    }

    @Test(arguments: [
        "9250004791234567890",   // wrong prefix
        "925000478123456789",    // too short
        "92500047812345678901",  // too long
        "925000478123456789A",   // not digits
    ])
    func illicadoRejectsNearMisses(_ pan: String) {
        #expect(!IllicadoConfig().validatePAN(pan))
    }

    @Test func illicadoAlwaysWantsAThreeDigitCVV() {
        let config = IllicadoConfig()
        #expect(config.requiresCVV(pan: "9250004781234567890"))
        #expect(config.validateCVV("123"))
        #expect(!config.validateCVV("12"))
        #expect(!config.validateCVV("1234"))
    }

    // MARK: BuyBox — three formats, and only one of them skips the CVV

    @Test func buyboxAcceptsStorelandOneyAndItsOwnFormat() {
        let config = BuyboxConfig()
        #expect(config.validatePAN("5331234567890"))            // Storeland
        #expect(config.validatePAN("1234567890123456789"))      // Oney, 19 digits
        #expect(config.validatePAN("A12345B123456"))            // BuyBox
    }

    /// Storeland cards carry no CVV; every other BuyBox card does. Getting this backwards asks the
    /// shopper for a code that does not exist.
    @Test func onlyStorelandSkipsTheCVV() {
        let config = BuyboxConfig()
        #expect(!config.requiresCVV(pan: "5331234567890"))
        #expect(config.requiresCVV(pan: "A12345B123456"))
    }

    /// The BuyBox format deliberately excludes I, L, O — the letters that look like digits.
    @Test(arguments: ["I12345B123456", "L12345B123456", "O12345B123456"])
    func buyboxExcludesAmbiguousLetters(_ pan: String) {
        #expect(!BuyboxConfig().validatePAN(pan))
    }

    // MARK: Take policies

    /// Loyalty and vouchers are non-splittable: they take the whole available amount or nothing.
    @Test func loyaltyAndVouchersAreNonSplittable() {
        #expect(MaxxingConfig().takePolicy == .max)
        #expect(Easy2playVoucherConfig().takePolicy == .max)
    }

    @Test func giftCardsAreSplittable() {
        #expect(IllicadoConfig().takePolicy == .none)
        #expect(BuyboxConfig().takePolicy == .none)
        #expect(OglobaConfig().takePolicy == .none)
        #expect(MybeezboxConfig().takePolicy == .none)
        #expect(Easy2playGiftcardConfig().takePolicy == .none)
    }

    // MARK: Payload shapes

    @Test func theDefaultPayloadIsACardNumberAndCode() {
        let payload = IllicadoConfig().buildInitPaymentData(pan: "9250004781234567890", cvv: "123")
        #expect(payload["card"]?["number"]?.stringValue == "9250004781234567890")
        #expect(payload["card"]?["csc"]?.stringValue == "123")
    }

    @Test func anAbsentCodeIsOmittedRatherThanSentEmpty() {
        let payload = OglobaConfig().buildInitPaymentData(pan: "123456789", cvv: nil)
        #expect(payload["card"]?["number"]?.stringValue == "123456789")
        #expect(payload["card"]?["csc"] == nil)
    }

    /// A voucher is not a card — it goes on the wire under its own key.
    @Test func aVoucherUsesItsOwnKey() {
        let payload = Easy2playVoucherConfig().buildInitPaymentData(pan: "V-123", cvv: nil)
        #expect(payload["voucher_number"]?.stringValue == "V-123")
        #expect(payload["card"] == nil)
    }

    // MARK: Parsing an /init answer

    private func method(partner: Partner = .illicado, method: PaymentMethod = .giftCard) -> SecondaryMethod {
        SecondaryMethod(
            id: "\(partner.wireValue)-\(method.wireValue)",
            partner: partner,
            method: method,
            configuration: MethodConfiguration(
                stable: true, template: nil, labels: ["secondary"], position: nil, vault: nil,
                settings: MethodSettings(
                    registrationMode: .unknown, saveToken: nil, saveTokenMode: nil,
                    directDebit: false, paymentMinAmount: nil, paymentMaxAmount: nil,
                    usagePerSessionLimit: 2, integrationMode: nil
                )
            ),
            disabled: nil
        )
    }

    private func cardInit(balance: JSONValue, expiry: String = "2030-12-31") -> JSONValue {
        .object([
            "status": .object(["state": "SUCCESS"]),
            "plugin_result": .object([
                "payment_data": .object([
                    "cards": .array([.object(["balance": balance, "expiry_date": .string(expiry)])]),
                ]),
                "logs": .object(["masked_card": "•••• 7890"]),
            ]),
        ])
    }

    @Test func parsesBalanceAndLabelFromAGiftCardInit() throws {
        let token = try IllicadoConfig().parseToken(
            method: method(),
            initResponse: cardInit(balance: .number("213.62")),
            pan: "9250004781234567890",
            cvv: "123"
        )

        #expect(token.balance == Decimal(string: "213.62"))
        #expect(token.name == "•••• 7890")
        #expect(token.expirationDate == "2030-12-31")
        #expect(token.takePolicy == .none)
        #expect(token.usageLimit == 2)
        // The id is per instrument, so two cards of the same method are distinct splits.
        #expect(token.id == "illicado-giftcard-7890")
    }

    /// Partners send the balance as a number or a quoted string; both must parse exactly.
    @Test(arguments: [JSONValue.number("50.00"), JSONValue.string("50.00")])
    func balanceParsesFromEitherWireShape(_ balance: JSONValue) throws {
        let token = try IllicadoConfig().parseToken(
            method: method(), initResponse: cardInit(balance: balance),
            pan: "9250004781234567890", cvv: "123"
        )
        #expect(token.balance == Decimal(string: "50.00"))
    }

    /// A card with nothing on it is not a usable instrument.
    @Test func anEmptyBalanceIsRefused() {
        #expect(throws: PurseCheckoutError.self) {
            try IllicadoConfig().parseToken(
                method: method(), initResponse: cardInit(balance: .number("0")),
                pan: "9250004781234567890", cvv: "123"
            )
        }
    }

    @Test func anUnsuccessfulInitIsRefused() {
        let refused = JSONValue.object(["status": .object(["state": "FAILED", "description": "unknown card"])])
        #expect(throws: PurseCheckoutError.self) {
            try IllicadoConfig().parseToken(
                method: method(), initResponse: refused, pan: "9250004781234567890", cvv: "123"
            )
        }
    }

    /// Maxxing puts the balance in `logs`, not on a card object — a different shape entirely.
    @Test func maxxingReadsItsBalanceFromLogs() throws {
        let response = JSONValue.object([
            "status": .object(["state": "SUCCESS"]),
            "plugin_result": .object([
                "logs": .object([
                    "eligible_euros": "12.50",
                    "total_euros": "40.00",
                    "customer.reference": "CUST-1",
                ]),
            ]),
        ])

        let token = try MaxxingConfig().parseToken(
            method: method(partner: .other("maxxing"), method: .other("loyaltycard")),
            initResponse: response, pan: "LOYAL-1", cvv: nil
        )

        #expect(token.balance == Decimal(string: "12.50"))
        #expect(token.totalBalance == Decimal(string: "40.00"))
        #expect(token.name == "CUST-1")
        #expect(token.takePolicy == .max)
    }

    // MARK: The registry

    @Test func everyShippedIssuerResolves() {
        let configs = SecondaryConfigs()
        #expect(configs.isRegistered(partner: .illicado, method: .giftCard))
        #expect(configs.isRegistered(partner: .other("buybox"), method: .giftCard))
        #expect(configs.isRegistered(partner: .other("maxxing"), method: .other("loyaltycard")))
        #expect(configs.isRegistered(partner: .other("ogloba"), method: .giftCard))
        #expect(configs.isRegistered(partner: .other("mybeezbox"), method: .giftCard))
        #expect(configs.isRegistered(partner: .other("easy2play"), method: .giftCard))
        #expect(configs.isRegistered(partner: .other("easy2play"), method: .other("voucher")))
    }

    /// `ancv-connect` needs a two-phase init that is not implemented; it is deliberately absent
    /// rather than half-working.
    @Test func ancvIsDeliberatelyAbsent() {
        #expect(!SecondaryConfigs().isRegistered(partner: .other("ancv"), method: .other("connect")))
    }

    /// The literal acceptance criterion: an out-of-catalogue issuer is added without an SDK change.
    @Test func aHostCanRegisterItsOwnIssuer() {
        struct MyIssuer: SecondaryConfig {
            let takePolicy = SecondaryTakePolicy.max
            func requiresCVV(pan: String) -> Bool { false }
            func validatePAN(_ pan: String) -> Bool { pan.hasPrefix("MY-") }
        }

        let configs = SecondaryConfigs()
        let partner = Partner.other("myissuer")
        let method = PaymentMethod.other("giftcard")
        #expect(!configs.isRegistered(partner: partner, method: method))

        configs.register(partner: partner, method: method, config: MyIssuer())

        let resolved = configs.config(partner: partner, method: method)
        #expect(resolved?.takePolicy == .max)
        #expect(resolved?.validatePAN("MY-123") == true)
        #expect(resolved?.validatePAN("OTHER") == false)
    }

    @Test func aHostCanOverrideAShippedIssuer() {
        struct Permissive: SecondaryConfig {
            let takePolicy = SecondaryTakePolicy.none
            func requiresCVV(pan: String) -> Bool { false }
            func validatePAN(_ pan: String) -> Bool { true }
        }

        let configs = SecondaryConfigs()
        configs.register(partner: .illicado, method: .giftCard, config: Permissive())
        #expect(configs.config(partner: .illicado, method: .giftCard)?.validatePAN("anything") == true)

        configs.reset()
        #expect(configs.config(partner: .illicado, method: .giftCard)?.validatePAN("anything") == false)
    }
}
