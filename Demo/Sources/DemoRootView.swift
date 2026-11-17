import SwiftUI

enum DemoMode: String, CaseIterable, Identifiable {
    case playground
    case checkout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playground: return "Playground"
        case .checkout: return "Checkout"
        }
    }

    var blurb: String {
        switch self {
        case .playground:
            return "Every method, every knob, and the raw session and transactions behind them. "
                + "Built for working on the SDK."
        case .checkout:
            return "What a shopper sees: a basket, a payment page, a confirmation. The same SDK "
                + "calls with none of the developer chrome."
        }
    }

    var icon: String {
        switch self {
        case .playground: return "sliders-horizontal"
        case .checkout: return "shopping-bag"
        }
    }
}

/// Picks a mode, then gets out of the way. Also hosts the snackbar, which both modes raise.
struct DemoRootView: View {
    @ObservedObject var controller: DemoController

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch controller.mode {
                case nil: ModePicker(controller: controller)
                case .playground?: DemoRouter(controller: controller)
                case .checkout?: CheckoutRouter(controller: controller)
                }
            }
            .transition(.opacity)
            .animation(PurseDS.motion, value: controller.mode)

            if let snackbar = controller.snackbar {
                Text(snackbar)
                    .font(PurseDS.regular(PurseDS.Size.caption))
                    .foregroundStyle(.white)
                    .padding(.horizontal, PurseDS.Space.l)
                    .padding(.vertical, PurseDS.Space.m)
                    .background(PurseDS.ink)
                    .clipShape(RoundedRectangle(cornerRadius: PurseDS.Radius.control))
                    .shadow(color: PurseDS.sheetShadow, radius: 24, x: 0, y: 8)
                    .padding(.bottom, 100)
                    .padding(.horizontal, PurseDS.Space.l)
                    .task(id: snackbar) {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        controller.snackbar = nil
                    }
            }
        }
    }
}

/// The one screen both modes share, so it carries the brand.
private struct ModePicker: View {
    @ObservedObject var controller: DemoController

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: PurseDS.Space.s) {
                HStack(spacing: PurseDS.Space.s) {
                    Circle().fill(PurseDS.accent).frame(width: 10, height: 10)
                    Text("Purse")
                        .font(PurseDS.semibold(PurseDS.Size.body))
                        .foregroundStyle(PurseDS.ink)
                }
                Text("Headless checkout")
                    .font(PurseDS.semibold(PurseDS.Size.display))
                    .tracking(-0.01 * PurseDS.Size.display)
                    .foregroundStyle(PurseDS.ink)
                Text("Two ways to drive the same SDK.")
                    .font(PurseDS.regular(PurseDS.Size.body))
                    .foregroundStyle(PurseDS.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PurseDS.Space.l)
            .padding(.top, PurseDS.Space.xl)
            .padding(.bottom, PurseDS.Space.l)

            ScrollView {
                VStack(alignment: .leading, spacing: PurseDS.Space.m) {
                    ForEach(DemoMode.allCases) { mode in
                        Button { controller.enter(mode) } label: {
                            PurseCard {
                                HStack(spacing: PurseDS.Space.m) {
                                    PurseIcon(mode.icon, size: 24).foregroundStyle(PurseDS.ink)
                                    Text(mode.title)
                                        .font(PurseDS.semibold(PurseDS.Size.bodyLarge))
                                        .foregroundStyle(PurseDS.ink)
                                    Spacer()
                                    PurseIcon("chevron-right", size: 20)
                                        .foregroundStyle(PurseDS.textSubtle)
                                }
                                Text(mode.blurb)
                                    .font(PurseDS.regular(PurseDS.Size.body))
                                    .foregroundStyle(PurseDS.textSecondary)
                                    .lineSpacing(PurseDS.bodyLineSpacing)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Text("Both modes mint real sessions through alfred and pay against the sandbox.")
                        .font(PurseDS.regular(PurseDS.Size.caption))
                        .foregroundStyle(PurseDS.textSubtle)
                        .padding(.top, PurseDS.Space.xs)
                }
                .padding(.horizontal, PurseDS.Space.l)
                .padding(.bottom, PurseDS.Space.xl)
            }
        }
        .background(PurseDS.surfaceMuted)
    }
}
