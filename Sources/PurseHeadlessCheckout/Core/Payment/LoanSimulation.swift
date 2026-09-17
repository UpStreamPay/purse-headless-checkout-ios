// Web: packages/headless-checkout `mapPluginResultToSimulation`
// Same: field names; counts and amounts only (no per-instalment dates on web either).
// Differs: `totalAmount` = initial + (n − 2) recurring + final. Web adds (n − 1) recurring, double-counting one instalment when `instalment_number` is the total; iOS takes Android's fix.

import Foundation

/// Web sdk's `LoanProduct` — what a BNPL partner needs to quote an instalment schedule.
public struct LoanProduct: Sendable {
    /// In major currency units.
    public let amount: Decimal
    /// ISO-4217, e.g. `"EUR"`.
    public let currencyCode: String

    public init(amount: Decimal, currencyCode: String) {
        self.amount = amount
        self.currencyCode = currencyCode
    }

    var payload: [String: JSONValue] {
        ["amount": .number(amount.description), "currency_code": .string(currencyCode)]
    }
}

/// Web sdk's `LoanSimulation`, mapped from a `plugin_result`. Amounts are in major currency units.
public struct LoanSimulation: Sendable, Equatable {
    /// `initial_instalment_amount`.
    public let initialInstallmentAmount: Decimal
    /// `final_instalment_amount`.
    public let finalInstallmentAmount: Decimal
    /// Each recurring instalment in between — `instalment_amount`.
    public let installmentAmount: Decimal
    /// `instalment_number`.
    public let installmentCount: Int
    /// `total_cost` — excludes the financed amount.
    public let totalCost: Decimal
    /// `initial + (count − 2) × installmentAmount + final`, rounded to two decimals.
    public let totalAmount: Decimal
    /// `legal_text`.
    public let legalText: String?
    /// `annual_nominal_rate`, else `effective_annual_percentage_rate`.
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

    /// `nil` when the response has no `plugin_result` — the single variant throws
    /// `INVALID_LOAN_SIMULATION` for that, the multi variant skips the candidate.
    static func fromResponse(_ response: JSONValue) -> LoanSimulation? {
        response["plugin_result"].map(fromPluginResult)
    }

    /// Web's `mapPluginResultToSimulation`.
    static func fromPluginResult(_ result: JSONValue) -> LoanSimulation {
        let initial = result["initial_instalment_amount"]?.asDecimal ?? 0
        let final = result["final_instalment_amount"]?.asDecimal ?? 0
        let recurring = result["instalment_amount"]?.asDecimal ?? 0
        let count = result["instalment_number"]?.intValue ?? 0

        // `instalment_number` counts the initial and final instalments too.
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
    /// Android's `RoundingMode.HALF_UP`: `.plain` rounds ties away from zero, which matches for the
    /// non-negative amounts a simulation carries.
    func rounded(scale: Int) -> Decimal {
        var result = Decimal()
        var value = self
        NSDecimalRound(&result, &value, scale, .plain)
        return result
    }
}
