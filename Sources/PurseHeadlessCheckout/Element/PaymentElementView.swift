// Web: the DOM container `appendTo` renders into.
// Same: the host decides where the partner's UI goes.
// Differs: Android's peer is a one-line `@Composable`; this adds the `UIViewRepresentable` every host would otherwise write.

import SwiftUI
import UIKit

/// Renders a ``PaymentElement``'s UI, or nothing when ``PaymentElement/hasUI`` is `false`. Give it
/// an `.id` that changes with the item's generation.
public struct PaymentElementView: UIViewRepresentable {

    private let element: PaymentElement
    /// Bumped by the container when the partner view's height changes after mounting — a card
    /// error wrapping to a second line — so SwiftUI measures again instead of clipping it.
    @State private var remeasure = 0

    public init(_ element: PaymentElement) {
        self.element = element
    }

    public func makeUIView(context: Context) -> UIView {
        let container = ElementContainer()
        let remeasure = $remeasure
        // Deferred: the layout pass may run inside SwiftUI's own view update.
        container.onHeightChange = { DispatchQueue.main.async { remeasure.wrappedValue += 1 } }
        guard let view = element.makeView() else { return container }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        _ = remeasure
    }

    /// Without this the container reports zero height in a `VStack` and the form collapses.
    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingCompressedSize.width

        if let height = Self.explicitHeight(proposal) {
            return CGSize(width: width, height: height)
        }

        let fitting = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: width, height: fitting.height)
    }

    final class ElementContainer: UIView {
        var onHeightChange: (() -> Void)?
        private var measuredHeight: CGFloat?

        override func layoutSubviews() {
            super.layoutSubviews()
            let height = systemLayoutSizeFitting(
                CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
            if let measuredHeight, measuredHeight != height {
                onHeightChange?()
            }
            measuredHeight = height
        }
    }

    /// The height a host explicitly asked for, or `nil` for the partner view's own. The partner view
    /// fills the container, and Apple Pay and PayPal have different intrinsic heights (~30pt vs
    /// ~43pt), so an express row stacking both would otherwise get two button heights.
    static func explicitHeight(_ proposal: ProposedViewSize) -> CGFloat? {
        guard let height = proposal.height, height.isFinite, height > 0 else { return nil }
        return height
    }
}
