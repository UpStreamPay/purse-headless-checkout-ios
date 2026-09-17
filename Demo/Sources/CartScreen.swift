import SwiftUI

/// Where the checkout flow starts: the session is minted behind the button, so alfred never shows.
struct CartScreen: View {
    @ObservedObject var controller: DemoController

    private let items = CartItem.sample
    private var subtotal: Decimal { CartItem.sampleSubtotal }
    /// Before a session exists there is no currency to read; the basket matches alfred's fixture.
    private var currency: String { controller.checkout?.currency ?? "EUR" }

    var body: some View {
        CheckoutScreen(
            title: "Your basket",
            subtitle: "\(items.count) items",
            onBack: controller.exitMode
        ) {
            PurseCard {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    LineItemRow(item: item, currency: currency)
                    if index < items.count - 1 {
                        Rectangle().fill(PurseDS.border).frame(height: 1)
                    }
                }
            }

            PurseCard {
                OrderSummary(
                    subtotal: subtotal,
                    currency: currency,
                    sessionAmount: controller.checkout?.session.amount
                )
            }

            if let error = controller.sessionError {
                PurseCard {
                    Text("We couldn't start the checkout")
                        .font(PurseDS.semibold(PurseDS.Size.body))
                        .foregroundStyle(PurseDS.danger)
                    Text(error)
                        .font(PurseDS.regular(PurseDS.Size.caption))
                        .foregroundStyle(PurseDS.textSecondary)
                        .textSelection(.enabled)
                }
            }
        } bottomAction: {
            PurseButton(
                title: "Checkout · \(amountText(controller.checkout?.session.amount ?? subtotal, currency))",
                loading: controller.creatingSession
            ) {
                controller.startCheckout()
            }
        }
    }
}
