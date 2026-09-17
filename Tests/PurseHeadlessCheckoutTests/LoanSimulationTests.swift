import Foundation
import Testing
@testable import PurseHeadlessCheckout

/// BNPL loan simulation: the corrected `totalAmount` arithmetic, `/simulation` parsing, and the
/// `simulable`-label gate on `PurseHeadlessCheckout`.
@MainActor
@Suite(.serialized)
struct LoanSimulationTests {

    /// A fictional root: `PaymentAPIClient` takes any `apiRoot`, and all four tiers are claimed.
    private static let host = "api.simulationtest.example"

    private func api() -> PaymentAPIClient {
        PaymentAPIClient(
            apiKey: "k", apiRoot: "https://\(Self.host)/payment/v1",
            entityId: "e", sessionId: "s", session: StubURLProtocol.session()
        )
    }

    // MARK: totalAmount arithmetic — Android's fix, not web's double-count

    @Test func aSingleInstallmentTotalsJustTheInitial() {
        let result = JSONValue.object([
            "initial_instalment_amount": .number("100"), "instalment_number": .number("1"),
            "instalment_amount": .number("0"), "final_instalment_amount": .number("0")
        ])
        let simulation = LoanSimulation.fromPluginResult(result)
        #expect(simulation.totalAmount == 100)
    }

    /// `instalment_number` counts every instalment, so the total is
    /// `initial + (count − 2) × recurring + final` — web's formula double-counts one.
    @Test func multipleInstallmentsUseTheCorrectedTotal() {
        let result = JSONValue.object([
            "initial_instalment_amount": .number("30"),
            "instalment_amount": .number("20"),
            "final_instalment_amount": .number("25"),
            "instalment_number": .number("4")
        ])
        let simulation = LoanSimulation.fromPluginResult(result)
        // 30 + (4-2)*20 + 25 = 95, not web's 30 + (4-1)*20 + 25 = 115.
        #expect(simulation.totalAmount == 95)
        #expect(simulation.installmentCount == 4)
    }

    @Test func totalAmountRoundsHalfUpToTwoDecimals() {
        let result = JSONValue.object([
            "initial_instalment_amount": .number("10.005"),
            "instalment_amount": .number("0"), "final_instalment_amount": .number("0"),
            "instalment_number": .number("1")
        ])
        #expect(LoanSimulation.fromPluginResult(result).totalAmount == 10.01)
    }

    @Test func aprcPrefersTheAnnualNominalRate() {
        let result = JSONValue.object([
            "annual_nominal_rate": .number("5.9"), "effective_annual_percentage_rate": .number("6.1"),
            "instalment_number": .number("0")
        ])
        #expect(LoanSimulation.fromPluginResult(result).aprc == 5.9)
    }

    @Test func aprcFallsBackToTheEffectiveRate() {
        let result = JSONValue.object([
            "effective_annual_percentage_rate": .number("6.1"), "instalment_number": .number("0")
        ])
        #expect(LoanSimulation.fromPluginResult(result).aprc == 6.1)
    }

    @Test func aResponseWithNoPluginResultParsesToNil() {
        #expect(LoanSimulation.fromResponse(.object(["status": .object(["state": "SUCCESS"])])) == nil)
    }

    // MARK: PaymentAPIClient.getSimulation / getSimulationMulti

    @Test func getSimulationParsesASuccessfulResponse() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set(
            "/simulation/e/klarna/installments",
            .ok(#"{"plugin_result":{"initial_instalment_amount":10,"instalment_amount":10,"final_instalment_amount":10,"instalment_number":3}}"#),
            host: Self.host
        )
        let simulation = try await api().getSimulation(
            partner: .klarna, method: .installments, product: LoanProduct(amount: 30, currencyCode: "EUR")
        )
        #expect(simulation.installmentCount == 3)
    }

    @Test func getSimulationThrowsInvalidLoanSimulationWithNoPluginResult() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set("/simulation/e/klarna/installments", .ok(#"{"status":{"state":"SUCCESS"}}"#), host: Self.host)
        do {
            _ = try await api().getSimulation(
                partner: .klarna, method: .installments, product: LoanProduct(amount: 30, currencyCode: "EUR")
            )
            Issue.record("expected getSimulation to throw")
        } catch let error as PaymentAPIError {
            #expect(error.errorCode == "INVALID_LOAN_SIMULATION")
        }
    }

    @Test func getSimulationMultiSkipsCandidatesWithNoPluginResult() async throws {
        StubURLProtocol.reset(host: Self.host)
        StubURLProtocol.set(
            "/simulation/e/klarna/installments/multi",
            .ok(#"[{"plugin_result":{"instalment_number":3}},{"status":{"state":"FAILED"}}]"#),
            host: Self.host
        )
        let simulations = try await api().getSimulationMulti(
            partner: .klarna, method: .installments, product: LoanProduct(amount: 30, currencyCode: "EUR")
        )
        #expect(simulations.count == 1)
    }

    // MARK: The `simulable` gate on PurseHeadlessCheckout

    private func checkout(simulable: Bool) throws -> (PurseHeadlessCheckout, PrimaryMethod) {
        let protocols = TestSessions.cardProtocol(labels: simulable ? ["simulable"] : [])
        let checkout = try PurseHeadlessCheckout(
            widgetData: TestSessions.widgetData(paymentSession: TestSessions.paymentSession(protocols: protocols)),
            urlSession: StubURLProtocol.session()
        )
        let method = try #require(checkout.paymentMethods.compactMap { item -> PrimaryMethod? in
            if case let .primaryMethod(method) = item { return method }
            return nil
        }.first)
        return (checkout, method)
    }

    @Test func aNonSimulableMethodIsRefusedWithoutTouchingTheNetwork() async throws {
        let (checkout, method) = try checkout(simulable: false)
        await #expect(throws: PurseCheckoutError.self) {
            _ = try await checkout.simulateLoan(method, product: LoanProduct(amount: 10, currencyCode: "EUR"))
        }
    }
}
