import PurseHeadlessCheckout
import SwiftUI

/// The order-confirmation page, and the demo's proof that a merchant can resolve a payment with the
/// SDK alone.
///
/// The playground's result screen asks **alfred** what happened. A real merchant has no alfred, so
/// this screen asks the session instead, through `awaitPaymentOutcome()`. That is the whole point of
/// this mode: the path here is one a merchant can actually ship.
struct ConfirmationScreen: View {
    @ObservedObject var controller: DemoController

    var body: some View {
        CheckoutScreen(title: heading, subtitle: "Order \(controller.orderReference)") {
            PurseCard(padding: PurseDS.Space.xl) {
                // The status mark is the one large accent on the page. Peppermint stays out of it:
                // a green tick and a red cross carry meaning the identity colour would muddy.
                ZStack {
                    Circle().fill(accent.opacity(0.12)).frame(width: 64, height: 64)
                    PurseIcon(symbol, size: 28).foregroundStyle(accent)
                }
                Text(heading)
                    .font(PurseDS.semibold(PurseDS.Size.title))
                    .tracking(-0.01 * PurseDS.Size.title)
                    .foregroundStyle(PurseDS.ink)
                Text(message)
                    .font(PurseDS.regular(PurseDS.Size.body))
                    .foregroundStyle(PurseDS.textSecondary)
                    .lineSpacing(PurseDS.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PurseCard {
                DetailLine(label: "Order", value: controller.orderReference)
                if let checkout = controller.checkout {
                    Rectangle().fill(PurseDS.border).frame(height: 1)
                    DetailLine(
                        label: "Amount",
                        value: amountText(checkout.session.amount, checkout.currency)
                    )
                }
                if let method = controller.result?.method {
                    Rectangle().fill(PurseDS.border).frame(height: 1)
                    DetailLine(label: "Paid with", value: method)
                }
            }

            if controller.confirming {
                HStack(spacing: PurseDS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Checking with your bank…")
                        .font(PurseDS.regular(PurseDS.Size.caption))
                        .foregroundStyle(PurseDS.textSubtle)
                }
            }

            if case .pending = controller.confirmedStatus, !controller.confirming {
                PurseSecondaryButton(title: "Check again") { controller.confirmPayment() }
            }
        } bottomAction: {
            PurseButton(title: "Back to shop") { controller.backToShop() }
        }
        // Asked once when the screen appears, exactly as a merchant's own confirmation page would.
        .task { controller.confirmPayment() }
    }

    /// The session's own verdict wins once there is one; until then the screen shows what the
    /// payment attempt itself reported.
    private var kind: DemoResult.Kind {
        switch controller.confirmedStatus {
        case .confirmed: return .authorized
        case .failed: return .failed
        case .pending, .none: return controller.result?.kind ?? .unconfirmed
        }
    }

    private var heading: String {
        switch kind {
        case .authorized: return "Order confirmed"
        case .failed: return "Payment failed"
        case .unconfirmed: return "Payment pending"
        }
    }

    private var message: String {
        switch kind {
        case .authorized:
            return "Your payment went through. A confirmation email is on its way."
        case .failed:
            return "Your payment didn't go through and you have not been charged. "
                + "Go back and try another method."
        case .unconfirmed:
            return "Your bank hasn't confirmed this payment yet. Don't pay again — "
                + "we'll email you as soon as it settles."
        }
    }

    private var symbol: String {
        switch kind {
        case .authorized: return "check"
        case .failed: return "x"
        case .unconfirmed: return "clock"
        }
    }

    private var accent: Color {
        switch kind {
        case .authorized: return PurseDS.success
        case .failed: return PurseDS.danger
        case .unconfirmed: return PurseDS.textSecondary
        }
    }
}

private struct DetailLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(PurseDS.regular(PurseDS.Size.body))
                .foregroundStyle(PurseDS.textSecondary)
            Spacer()
            Text(value)
                .font(PurseDS.regular(PurseDS.Size.body))
                .foregroundStyle(PurseDS.ink)
                .textSelection(.enabled)
        }
    }
}
