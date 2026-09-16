import SwiftUI

@main
struct DemoApp: App {
    @StateObject private var controller = DemoController()

    var body: some Scene {
        WindowGroup {
            DemoRouter(controller: controller)
                // Android never tears down on Activity destroy. This does.
                .onDisappear { controller.teardownCheckout() }
                // `-demo-autostart` mints a session and opens the pay screen, so a smoke test
                // reaches the methods without a tap. Never on by default.
                .task {
                    guard CommandLine.arguments.contains("-demo-autostart") else { return }
                    controller.createSession()
                    while controller.checkout == nil, !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    controller.goToPay()
                }
        }
    }
}

/// Three screens off one controller, plus the snackbar and the back gesture.
struct DemoRouter: View {
    @ObservedObject var controller: DemoController

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch controller.step {
                case .session: SessionScreen(controller: controller)
                case .pay: PayScreen(controller: controller)
                case .result: ResultScreen(controller: controller)
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: controller.step)

            if let snackbar = controller.snackbar {
                Text(snackbar)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 100)
                    .padding(.horizontal, 20)
                    .task(id: snackbar) {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        controller.snackbar = nil
                    }
            }
        }
    }
}
