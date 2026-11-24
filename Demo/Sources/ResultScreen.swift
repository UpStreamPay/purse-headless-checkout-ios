import SwiftUI

struct ResultScreen: View {
    @ObservedObject var controller: DemoController

    var body: some View {
        DemoScreen(step: 3, title: "Result", onBack: controller.back) {
            if let result = controller.result {
                StatusBanner(result: result)
            }

            DemoCard {
                Text("Transactions").font(.title3.weight(.semibold))
                TextField("Session id", text: $controller.alfredSessionId)
                    .font(DemoTheme.mono)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                SmallButton(
                    text: "Get transactions",
                    loading: controller.loadingTransactions,
                    enabled: !controller.alfredSessionId.isEmpty
                ) { controller.getTransactions() }

                ForEach(Array(controller.transactions.enumerated()), id: \.offset) { _, transaction in
                    let action = transaction["status"]?["action"]?.string ?? "?"
                    let state = transaction["status"]?["state"]?.string ?? "?"
                    Text("\(action) → \(state)")
                        .font(.subheadline)
                        .foregroundStyle(state == "SUCCESS" ? DemoTheme.success : DemoTheme.failure)
                }

                if !controller.rawTransactions.isEmpty {
                    Disclosure(title: "Raw response") { MonoBlock(controller.rawTransactions) }
                }
            }

            DemoCard {
                Text("Capture").font(.title3.weight(.semibold))
                if controller.capturePaymentId.isEmpty {
                    Text("No payment_id was reported — paste one to capture.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                TextField("Payment id", text: $controller.capturePaymentId)
                    .font(DemoTheme.mono)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                TextField("Amount", text: $controller.captureAmount)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                SmallButton(
                    text: "Capture",
                    loading: controller.capturing,
                    enabled: !controller.capturePaymentId.isEmpty
                ) { controller.capture() }
                if !controller.captureRaw.isEmpty { MonoBlock(controller.captureRaw) }
            }

            EventLog(events: controller.events)
        } bottomAction: {
            BigButton(text: "Start a new payment") { controller.startOver() }
        }
    }
}

private struct StatusBanner: View {
    let result: DemoResult

    private var accent: Color {
        switch result.kind {
        case .authorized: DemoTheme.success
        case .failed: DemoTheme.failure
        case .unconfirmed: DemoTheme.warning
        }
    }

    var body: some View {
        DemoCard {
            HStack(spacing: 16) {
                Image(systemName: result.symbol)
                    .font(.title.weight(.bold))
                    .foregroundStyle(accent)
                    .frame(width: 64, height: 64)
                    .background(accent.opacity(0.14))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title).font(.title3.weight(.semibold))
                    Text("via \(result.method)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Text(result.detail).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
