import PurseHeadlessCheckout
import UIKit

/// The whole point of this screen: build a checkout, get a real `PluginHost` for a saved no-CVV
/// card, drive it through `CardCoordinator`, and submit — the same four calls any merchant
/// integration makes, end to end.
@MainActor
final class DemoViewController: UIViewController {
    private var checkout: PurseHeadlessCheckout?
    private var cardCoordinator: CardCoordinator?

    private let amountLabel = UILabel()
    private let payButton = UIButton(type: .system)
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Purse Headless Checkout"
        layout()

        do {
            try start()
        } catch {
            statusLabel.text = "Failed to start: \(error)"
        }
    }

    private func layout() {
        amountLabel.font = .preferredFont(forTextStyle: .title1)
        amountLabel.textAlignment = .center

        payButton.setTitle("Pay with saved card", for: .normal)
        payButton.addTarget(self, action: #selector(payTapped), for: .touchUpInside)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [amountLabel, payButton, statusLabel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24)
        ])
    }

    private func start() throws {
        MockURLProtocol.handlers["/validate"] = MockURLProtocol.MockResponse(
            data: Data(#"{"global_status":"SUCCESS","results":[{"status":{"state":"SUCCESS"}}]}"#.utf8),
            statusCode: 200
        )

        let checkout = try PurseHeadlessCheckout(
            widgetData: Self.demoWidgetData(),
            urlSession: MockURLProtocol.makeSession()
        )
        self.checkout = checkout
        amountLabel.text = "\(checkout.session.amount) \(checkout.session.currency)"

        guard let token = checkout.paymentTokens.first else {
            statusLabel.text = "No saved card in the demo session"
            return
        }

        // The seam this Demo exists to prove out: a real PluginHost, driving a real coordinator,
        // against a real (if canned) checkout — see PurseHeadlessCheckout.host(for:).
        let host = try checkout.host(for: token)
        let coordinator = CardCoordinator(
            host: host,
            tenantId: "demo-tenant",
            supportedBrands: [],
            token: host.buildContext().token
        )
        cardCoordinator = coordinator
        try host.setAsPrimary()

        statusLabel.text = "Ready — \(coordinator.mode)"
    }

    @objc private func payTapped() {
        guard let checkout, let coordinator = cardCoordinator else { return }
        payButton.isEnabled = false
        Task {
            do {
                // A no-CVV saved token renders no form and tokenizes nothing — submit() is a no-op
                // here, but it's the same call a fresh-card or CVV flow would make first.
                _ = try await coordinator.submit()
                let result = try await checkout.submitPayment()
                statusLabel.text = "Payment: \(result.globalStatus)"
            } catch {
                statusLabel.text = "Error: \(error)"
            }
            payButton.isEnabled = true
        }
    }

    /// A hand-built `widget.data` — one Purse-vaulted card method with a single saved token that
    /// pays without a CVV (`merchant_specifics.pay_token_no_cvv`). The shape a real backend's
    /// Client Session response carries; see `docs/plugins/card-purse-vault.md`-equivalent for iOS.
    private static func demoWidgetData() -> String {
        let session: [String: Any] = [
            "id": "demo-session-1",
            "amount": 42.50,
            "currency_code": "EUR",
            "expiration_date": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)),
            "protocols": [
                "purse": [
                    "creditcard": [
                        "configurations": [
                            "stable": true,
                            "labels": [],
                            "vault": ["vendor": "purse", "supported_brands": ["VISA"]],
                            "settings": ["merchant_specifics": ["pay_token_no_cvv": true]]
                        ],
                        "integrated_tokens": [[
                            "id": "demo-token-1",
                            "value": "vault-token-1",
                            "name": "My card",
                            "description": ["masked_pan": "•••• 4242", "brand_name": "VISA"]
                        ]]
                    ]
                ]
            ],
            "vault": ["vendor_front_data": ["purse": ["tenant_id": "demo-tenant"]]]
        ]
        let blob: [String: Any] = [
            "api_key": "demo-key",
            "api_url": "https://api.purse-sandbox.com",
            "environment": "sandbox",
            "entity_id": "demo-entity",
            "payment_session": session
        ]
        let data = try! JSONSerialization.data(withJSONObject: blob)
        return data.base64EncodedString()
    }
}
