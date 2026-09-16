// Web: the DOM container `appendTo` renders into.
// Same: the host decides where the partner's UI goes.
// Differs: Android's peer is a one-line `@Composable`; this is that plus the `UIViewRepresentable` every host would otherwise write.

import SwiftUI
import UIKit

/// Renders a ``PaymentElement``'s UI, or nothing when ``PaymentElement/hasUI`` is `false`. Give it
/// an `.id` that changes with the item's generation.
public struct PaymentElementView: UIViewRepresentable {

    private let element: PaymentElement

    public init(_ element: PaymentElement) {
        self.element = element
    }

    public func makeUIView(context: Context) -> UIView {
        let container = UIView()
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

    public func updateUIView(_ uiView: UIView, context: Context) {}

    /// Without this the container reports zero height in a `VStack` and the form collapses.
    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingCompressedSize.width
        let fitting = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: width, height: fitting.height)
    }
}
