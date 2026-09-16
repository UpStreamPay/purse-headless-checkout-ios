import PurseHeadlessCheckout
import SwiftUI

/// The BNPL instalment schedule, rendered by the **host** — the SDK returns the numbers, not a view.
/// Re-quoted whenever the remaining amount moves.
struct SimulationPreview: View {
    @ObservedObject var controller: DemoController
    let method: PrimaryMethod

    @State private var simulation: LoanSimulation?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let simulation {
                let currency = controller.checkout?.currency ?? ""
                // The API gives first / recurring / last and a count, not a list.
                ForEach(0..<simulation.installmentCount, id: \.self) { index in
                    HStack {
                        Text("Instalment \(index + 1)\(index == 0 ? " · today" : "")").font(.footnote)
                        Spacer()
                        Text(amountText(Self.amount(at: index, of: simulation), currency))
                            .font(DemoTheme.mono)
                    }
                }
                HStack {
                    Text("Cost of credit").font(.footnote)
                    Spacer()
                    Text(amountText(simulation.totalCost, currency)).font(DemoTheme.mono)
                }
                HStack {
                    Text("Total").font(.footnote.weight(.semibold))
                    Spacer()
                    Text(amountText(simulation.totalAmount, currency)).font(DemoTheme.mono.weight(.semibold))
                }
                if let aprc = simulation.aprc {
                    Text("APR \(aprc) %").font(.caption2).foregroundStyle(.secondary)
                }
                if let legal = simulation.legalText, !legal.isEmpty {
                    Text(legal).font(.caption2).foregroundStyle(.secondary)
                }
            } else if failed {
                Text("No instalment schedule available for this amount.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Computing your instalments…").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: controller.checkout?.remainingAmountToPay) {
            guard let checkout = controller.checkout else { return }
            failed = false
            simulation = nil
            do {
                simulation = try await checkout.simulateLoan(
                    method,
                    product: LoanProduct(amount: checkout.remainingAmountToPay, currencyCode: checkout.currency)
                )
            } catch {
                failed = true
            }
        }
    }

    private static func amount(at index: Int, of simulation: LoanSimulation) -> Decimal {
        if index == 0 { return simulation.initialInstallmentAmount }
        if index == simulation.installmentCount - 1 { return simulation.finalInstallmentAmount }
        return simulation.installmentAmount
    }
}
