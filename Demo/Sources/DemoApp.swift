import SwiftUI

@main
struct DemoApp: App {
    @StateObject private var controller = DemoController()

    var body: some Scene {
        WindowGroup {
            DemoRootView(controller: controller)
                // Android never tears down on Activity destroy. This does.
                .onDisappear { controller.teardownCheckout() }
                // `-demo-autostart` mints a session and opens the playground's pay screen so a
                // smoke test needs no tap; `-demo-checkout` opens the shopper flow at its basket.
                .task {
                    let arguments = CommandLine.arguments
                    let autostart = arguments.contains("-demo-autostart")
                    if arguments.contains("-demo-checkout") {
                        controller.enter(.checkout)
                        // With `-demo-autostart` too, land straight on the payment page.
                        if autostart { controller.startCheckout() }
                        return
                    }
                    guard autostart else { return }
                    controller.enter(.playground)
                    controller.createSession()
                    while controller.checkout == nil, !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    controller.goToPay()
                }
        }
    }
}

/// The playground's three screens off one controller. The snackbar lives on `DemoRootView` instead,
/// which both modes sit inside — two hosts would show it twice.
struct DemoRouter: View {
    @ObservedObject var controller: DemoController

    var body: some View {
        Group {
            switch controller.step {
            case .session: SessionScreen(controller: controller)
            case .pay: PayScreen(controller: controller)
            case .result: ResultScreen(controller: controller)
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: controller.step)
    }
}
