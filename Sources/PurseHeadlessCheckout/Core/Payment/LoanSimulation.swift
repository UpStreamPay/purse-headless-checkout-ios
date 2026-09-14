// Web: packages/headless-checkout `mapPluginResultToSimulation`
// Same: field names; counts and amounts only (no per-instalment dates on web either).
// Differs: `totalAmount` = initial + (n − 2) recurring + final. Web adds (n − 1) recurring on top of initial and final, which counts one instalment twice when `instalment_number` is the total — Android's fix (see the web↔Android↔iOS map), which iOS also takes.

import Foundation

/// What a BNPL partner needs to quote an instalment schedule — web sdk's `LoanProduct`. Serialized
/// as `{"amount": <number>, "currency_code": "EUR"}` for `POST
/// /simulation/{entityId}/{partner}/{method}`.
public struct LoanProduct: Sendable {
    /// Amount to finance, in major currency units.
    public let amount: Decimal
    /// ISO-4217 code, e.g. `"EUR"`.
    public let currencyCode: String

    public init(amount: Decimal, currencyCode: String) {
        self.amount = amount
        self.currencyCode = currencyCode
    }

    var payload: [String: JSONValue] {
        ["amount": .number(amount.description), "currency_code": .string(currencyCode)]
    }
}

/// One BNPL instalment schedule — web sdk's `LoanSimulation`, mapped from the simulation API's
/// `plugin_result` exactly as `mapPluginResultToSimulation` does. Amounts are in major currency
/// units.
public struct LoanSimulation: Sendable, Equatable {
    /// First instalment — `initial_instalment_amount`.
    public let initialInstallmentAmount: Decimal
    /// Last instalment — `final_instalment_amount`.
    public let finalInstallmentAmount: Decimal
    /// Each recurring instalment in between — `instalment_amount`.
    public let installmentAmount: Decimal
    /// Number of instalments — `instalment_number`.
    public let installmentCount: Int
    /// Cost of the loan, excluding the financed amount — `total_cost`.
    public let totalCost: Decimal
    /// Everything the shopper pays: `initial + (count − 2) × installmentAmount + final`, rounded to
    /// two decimals.
    public let totalAmount: Decimal
    /// Legal wording some partners require next to the offer — `legal_text`.
    public let legalText: String?
    /// Annual percentage rate — `annual_nominal_rate`, else `effective_annual_percentage_rate`.
    public let aprc: Decimal?

    public init(
        initialInstallmentAmount: Decimal,
        finalInstallmentAmount: Decimal,
        installmentAmount: Decimal,
        installmentCount: Int,
        totalCost: Decimal,
        totalAmount: Decimal,
        legalText: String?,
        aprc: Decimal?
    ) {
        self.initialInstallmentAmount = initialInstallmentAmount
        self.finalInstallmentAmount = finalInstallmentAmount
        self.installmentAmount = installmentAmount
        self.installmentCount = installmentCount
        self.totalCost = totalCost
        self.totalAmount = totalAmount
        self.legalText = legalText
        self.aprc = aprc
    }

    /// The simulation carried by a `/simulation` response, or `nil` when it has no `plugin_result`
    /// (web throws `INVALID_LOAN_SIMULATION` for that; the multi variant skips such candidates
    /// instead of failing the whole call).
    static func fromResponse(_ response: JSONValue) -> LoanSimulation? {
        response["plugin_result"].map(fromPluginResult)
    }

    /// Map a `plugin_result` block — web's `mapPluginResultToSimulation`.
    static func fromPluginResult(_ result: JSONValue) -> LoanSimulation {
        let initial = result["initial_instalment_amount"]?.asDecimal ?? 0
        let final = result["final_instalment_amount"]?.asDecimal ?? 0
        let recurring = result["instalment_amount"]?.asDecimal ?? 0
        let count = result["instalment_number"]?.intValue ?? 0

        // `instalment_number` counts every instalment: the initial one, the recurring ones and the
        // final one. A single instalment is just the initial amount.
        let rawTotal: Decimal = count <= 1 ? initial : initial + recurring * Decimal(count - 2) + final

        return LoanSimulation(
            initialInstallmentAmount: initial,
            finalInstallmentAmount: final,
            installmentAmount: recurring,
            installmentCount: count,
            totalCost: result["total_cost"]?.asDecimal ?? 0,
            totalAmount: rawTotal.rounded(scale: 2),
            legalText: result["legal_text"]?.stringValue?.nonBlank,
            aprc: result["annual_nominal_rate"]?.asDecimal ?? result["effective_annual_percentage_rate"]?.asDecimal
        )
    }
}

private extension Decimal {
    /// `RoundingMode.HALF_UP` — `.plain` rounds a tie away from zero, the same behaviour for the
    /// non-negative amounts a loan simulation carries.
    func rounded(scale: Int) -> Decimal {
        var result = Decimal()
        var value = self
        NSDecimalRound(&result, &value, scale, .plain)
        return result
    }
}
