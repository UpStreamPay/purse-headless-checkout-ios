// Web: none — web navigates the page itself.
// Same: —
// Differs: two paths. ASWebAuthenticationSession for a GET (a real browser, so ACS providers that refuse embedded web views still render); WKWebView for the POST cases, because no system browser can POST — the same constraint Android hit.

import AuthenticationServices
import Foundation
import UIKit
import WebKit

/// The default ``RedirectPresenter``. A `.get` goes to `ASWebAuthenticationSession`.
@MainActor
public final class WebAuthRedirectPresenter: NSObject, RedirectPresenter {

    private let policy: RedirectPolicy
    private weak var presentingViewController: UIViewController?
    private var session: ASWebAuthenticationSession?

    /// - Parameters: - policy: where the redirect may go, and what counts as coming back. -
    /// presentingViewController: used for the POST cases, which are presented modally. The GET case
    /// anchors on the app's key window.
    public init(policy: RedirectPolicy, presentingViewController: UIViewController? = nil) {
        self.policy = policy
        self.presentingViewController = presentingViewController
    }

    public func present(_ action: RedirectAction) async throws -> RedirectOutcome {
        switch action {
        case let .get(url, _):
            guard let url = URL(string: url) else {
                throw PartnerUIError("redirect url is not a usable URL: \(url)")
            }
            guard policy.allowsLoading(url) else {
                throw PartnerUIError("refused redirect url: \(url.absoluteString)")
            }
            return try await presentWebAuthentication(url)

        case .postForm, .postHTML:
            return try await presentWebView(action)
        }
    }

    // MARK: GET — the browser

    private func presentWebAuthentication(_ url: URL) async throws -> RedirectOutcome {
        try await withCheckedThrowingContinuation { continuation in
            let completion: @Sendable (URL?, (any Error)?) -> Void = { callbackURL, error in
                MainActor.assumeIsolated {
                    self.session = nil
                    if let error {
                        // A dismissed sheet is a cancel, not a failure — the shopper may try again.
                        let isCancel = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                        if isCancel {
                            continuation.resume(returning: .canceled)
                        } else {
                            continuation.resume(throwing: PartnerUIError("redirect failed", underlying: error))
                        }
                        return
                    }
                    // Reaching the callback means the shopper came back. It does **not** mean the
                    // payment succeeded: confirm against the session.
                    _ = callbackURL
                    continuation.resume(returning: .returned)
                }
            }

            let session: ASWebAuthenticationSession
            if #available(iOS 17.4, *), case let .universalLink(host, path) = policy.returnDestination {
                session = ASWebAuthenticationSession(
                    url: url,
                    callback: .https(host: host, path: path),
                    completionHandler: completion
                )
            } else {
                // Below 17.4 the system can only match a custom scheme. A Universal Link policy still
                // works — the link opens the app and the flow resumes there — but the session itself
                // cannot observe it, so it is dismissed rather than completed.
                session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: policy.callbackScheme,
                    completionHandler: completion
                )
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            guard session.start() else {
                self.session = nil
                continuation.resume(throwing: PartnerUIError("could not start the redirect session"))
                return
            }
        }
    }

    // MARK: POST — a real web view

    private func presentWebView(_ action: RedirectAction) async throws -> RedirectOutcome {
        guard let presenter = presentingViewController ?? Self.keyWindow?.rootViewController else {
            throw PartnerUIError(
                "no view controller to present the redirect from — pass presentingViewController"
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            let controller = RedirectWebViewController(action: action, policy: policy) { outcome in
                continuation.resume(with: outcome)
            }
            let navigation = UINavigationController(rootViewController: controller)
            navigation.modalPresentationStyle = .formSheet
            presenter.present(navigation, animated: true)
        }
    }

    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

extension WebAuthRedirectPresenter: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        Self.keyWindow ?? ASPresentationAnchor()
    }
}

/// Hosts the POST cases. Navigation is gated by the same ``RedirectPolicy`` as the GET case.
@MainActor
final class RedirectWebViewController: UIViewController, WKNavigationDelegate {

    private let action: RedirectAction
    private let policy: RedirectPolicy
    private var completion: ((Result<RedirectOutcome, any Error>) -> Void)?
    private lazy var webView = WKWebView(frame: .zero, configuration: configuration)

    private var configuration: WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // Nothing in a challenge chain needs to read local files.
        configuration.preferences.isTextInteractionEnabled = true
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }

    init(
        action: RedirectAction,
        policy: RedirectPolicy,
        completion: @escaping (Result<RedirectOutcome, any Error>) -> Void
    ) {
        self.action = action
        self.policy = policy
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped)
        )

        load()
    }

    private func load() {
        switch action {
        case let .postForm(url, formData, _):
            guard let url = URL(string: url), policy.allowsLoading(url) else {
                finish(.failure(PartnerUIError("refused redirect url: \(action.targetURL ?? "")")))
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(formData.utf8)
            webView.load(request)

        case let .postHTML(html, _):
            // The server sent literal markup to inject and auto-submit. There is no base URL to
            // resolve against, which also means relative loads cannot escape to an unexpected host.
            webView.loadHTMLString(html, baseURL: nil)

        case .get:
            finish(.failure(PartnerUIError("a GET redirect belongs in the browser, not this view")))
        }
    }

    @objc private func cancelTapped() {
        finish(.success(.canceled))
    }

    // The signature must match WKNavigationDelegate's exactly, `@MainActor @Sendable` included.
    // A near-miss compiles, is never called, and the allowlist below silently never runs.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if policy.isReturn(url) {
            decisionHandler(.cancel)
            finish(.success(.returned))
            return
        }

        // The widget's own confirmation hop is not a destination worth rendering — it carries the
        // result the caller already has, and is caught even when no return URL is configured.
        if url.absoluteString.isWidgetConfirmationRedirect {
            decisionHandler(.cancel)
            finish(.success(.returned))
            return
        }

        decisionHandler(policy.allowsLoading(url) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(PartnerUIError("redirect navigation failed", underlying: error)))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(.failure(PartnerUIError("redirect navigation failed", underlying: error)))
    }

    private func finish(_ result: Result<RedirectOutcome, any Error>) {
        guard let completion else { return }
        self.completion = nil
        dismiss(animated: true) { completion(result) }
    }
}
