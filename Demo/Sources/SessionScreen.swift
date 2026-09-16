import PurseHeadlessCheckout
import SwiftUI

struct SessionScreen: View {
    @ObservedObject var controller: DemoController

    var body: some View {
        DemoScreen(step: 1, title: "Session") {
            Text("Mint an orchestration session through alfred.")
                .font(.body)
                .foregroundStyle(.secondary)

            DemoCard {
                LabeledValue(label: "alfred", value: controller.alfredBaseURL, mono: true)
                BigButton(
                    text: controller.creatingSession ? "Creating session…" : "Create session",
                    loading: controller.creatingSession
                ) { controller.createSession() }

                Disclosure(title: "Paste a widget.data instead") {
                    TextEditor(text: $controller.widgetData)
                        .font(DemoTheme.mono)
                        .frame(minHeight: 90, maxHeight: 160)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(uiColor: .separator)))
                    SmallButton(text: "Use this widget.data", enabled: !controller.widgetData.isEmpty) {
                        controller.initCheckout()
                    }
                }
            }

            if let error = controller.sessionError { ErrorCard(error) }

            if let checkout = controller.checkout {
                DemoCard(tinted: true) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(amountText(checkout.session.amount, checkout.currency))
                            .font(.title.weight(.semibold))
                        Spacer()
                        Text("Session ready").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("\(checkout.paymentMethods.count) payment methods")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Disclosure(title: "Session details") { MonoBlock(controller.sessionDetails) }
                }
            }
        } bottomAction: {
            BigButton(text: "Continue to payment", enabled: controller.checkout != nil) {
                controller.goToPay()
            }
        }
    }
}
