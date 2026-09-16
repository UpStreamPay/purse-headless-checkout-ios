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
    private let prefersInAppWebView: Bool
    private var session: ASWebAuthenticationSession?

    /// - Parameters: - policy: where the redirect may go, and what counts as coming back. -
    /// presentingViewController: used for the POST cases, which are presented modally. The GET case
    /// anchors on the app's key window.
    public init(
        policy: RedirectPolicy,
        presentingViewController: UIViewController? = nil,
        prefersInAppWebView: Bool = false
    ) {
        self.policy = policy
        self.presentingViewController = presentingViewController
        self.prefersInAppWebView = prefersInAppWebView
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
            // Only when the browser can actually observe the end of the flow — otherwise the web
            // view, which watches every navigation itself and works on every supported iOS.
            guard !prefersInAppWebView, browserCanObserveReturn else {
                return try await presentWebView(action)
            }
            return try await presentWebAuthentication(url)

        case .postForm, .postHTML:
            return try await presentWebView(action)
        }
    }

    /// Whether `ASWebAuthenticationSession` can see this policy's return destination. A custom
    /// scheme it can always match.
    private var browserCanObserveReturn: Bool {
        switch policy.returnDestination {
        case .customScheme:
            return true
        case .universalLink:
            if #available(iOS 17.4, *) { return true }
            return false
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
                    // payment succeeded: confirm against the session. The URL travels with it
                    // because it carries the reported status.
                    continuation.resume(returning: .returned(url: callbackURL))
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
                // A custom scheme — the only destination this initialiser can match, and the only
                // policy routed here at all (see `browserCanObserveReturn`).
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
            // A `.formSheet` is interactively dismissible: dragging it down tears the navigation
            // controller off screen without `cancelTapped` and without any delegate callback, so
            // the continuation below would never resume — the caller awaits forever on a payment
            navigation.isModalInPresentation = true
            // Belt and braces: if the gesture is ever re-enabled, or the system dismisses the sheet
            // for its own reasons, this reports it as a cancel rather than leaving a suspended task.
            navigation.presentationController?.delegate = controller
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
final class RedirectWebViewController: UIViewController, WKNavigationDelegate,
    UIAdaptivePresentationControllerDelegate {

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

    /// What the first navigation should be. Pulled out of ``load()`` so it can be tested without a
    /// view lifecycle: the `.get` case was unreachable and answered "a GET redirect belongs in the
    /// browser, not this view" until `prefersInAppWebView` started routing here, and nothing could
    enum FirstLoad: Equatable {
        case request(URL)
        case html(String, baseURL: URL?)
        case refused(String)
    }

    static func firstLoad(for action: RedirectAction, policy: RedirectPolicy) -> FirstLoad {
        func allowed(_ raw: String) -> URL? {
            guard let url = URL(string: raw), policy.allowsLoading(url) else { return nil }
            return url
        }

        switch action {
        case let .postForm(url, formData, _):
            guard let url = allowed(url) else { return .refused(action.targetURL ?? "") }
            // Not `URLRequest.httpBody` + `load(_:)`: WebKit drops the body of a `load(_:)` request,
            // so the ACS would get an empty POST and answer 400 — see `FormRedirectHTML`.
            return .html(
                FormRedirectHTML.autoSubmitting(actionURL: url.absoluteString, dataString: formData),
                baseURL: url
            )

        case let .postHTML(html, _):
            // The server sent literal markup to inject and auto-submit. There is no base URL to
            // resolve against, which also means relative loads cannot escape to an unexpected host.
            return .html(html, baseURL: nil)

        case let .get(url, _):
            // Reached when the host set `prefersInAppWebView`, which is what Android does for every
            // case. Policy is re-checked here because this is the only gate on the first
            // navigation — the delegate below sees every hop after it, not this one.
            guard let url = allowed(url) else { return .refused(action.targetURL ?? "") }
            return .request(url)
        }
    }

    private func load() {
        switch Self.firstLoad(for: action, policy: policy) {
        case let .request(url):
            webView.load(URLRequest(url: url))
        case let .html(html, baseURL):
            webView.loadHTMLString(html, baseURL: baseURL)
        case let .refused(url):
            finish(.failure(PartnerUIError("refused redirect url: \(url)")))
        }
    }

    /// Whether `url` is the return URL the session configured, carried on the action itself.
    private func isConfiguredReturn(_ url: URL) -> Bool {
        guard let prefix = action.returnURLPrefix, !prefix.isEmpty else { return false }
        return url.absoluteString.hasPrefix(prefix)
    }

    @objc private func cancelTapped() {
        finish(.success(.canceled))
    }

    /// The sheet went away without Cancel being tapped. Report a cancel rather than leaving the
    /// caller suspended: the view is already gone, so there is nothing left to dismiss.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let completion else { return }
        self.completion = nil
        completion(.success(.canceled))
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

        // The policy's own destination, **or** the return URL the session configured and this
        // action carries.
        if policy.isReturn(url) || isConfiguredReturn(url) {
            decisionHandler(.cancel)
            finish(.success(.returned(url: url)))
            return
        }

        // The widget's own confirmation hop is not a destination worth rendering — it carries the
        // result the caller already has, and is caught even when no return URL is configured.
        if url.absoluteString.isWidgetConfirmationRedirect {
            decisionHandler(.cancel)
            finish(.success(.returned(url: url)))
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
