import SwiftUI

enum CheckoutStep { case cart, pay, confirmation }

/// Cart → pay → confirmation, off the same `DemoController` the playground uses. One controller,
/// one session-minting path: two would be two things to keep in step.
struct CheckoutRouter: View {
    @ObservedObject var controller: DemoController

    var body: some View {
        Group {
            switch controller.checkoutStep {
            case .cart: CartScreen(controller: controller)
            case .pay: CheckoutPayScreen(controller: controller)
            case .confirmation: ConfirmationScreen(controller: controller)
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: controller.checkoutStep)
    }
}
