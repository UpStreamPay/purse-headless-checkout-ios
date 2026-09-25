// Web: none — web navigates the page and never sees the answer come back.
// Same: `/validate`, then web's `manageRedirection` on the answer.
// Differs: smaller than Android's `PaymentCoordinator.capture` — `presentRedirectIfNeeded` already does what Android's `RedirectDispatcher`/`shouldFollow` do.

import Foundation

/// Where every element's submit ends: `/validate`, the redirect it asked for, one outcome.
enum ElementFlow {

    @MainActor
    static func capture(
        host: any PluginHost,
        checkout: PurseHeadlessCheckout,
        presenter: (any RedirectPresenter)?,
        listener: any PaymentElementListener
    ) async {
        let result: ValidationResult
        do {
            result = try await host.submitPayment()
        } catch {
            listener.onOutcome(.failed(error.asPurseError()))
            return
        }

        // Read before the redirect is followed — after that the URL stops being ours to inspect.
        if let paymentId = result.redirection?.url?.widgetConfirmationPaymentId {
            listener.onPaymentId(paymentId)
        }

        // No presenter is a choice, not an error: the caller said they would follow it themselves,
        // and `pendingRedirect(for:)` is public so they can.
        guard checkout.pendingRedirect(for: result) != nil, let presenter else {
            listener.onOutcome(.completed(result))
            return
        }

        // A session success/failure page is shown, not followed: the answer is already the outcome.
        if checkout.responseRedirect(for: result) == nil {
            _ = try? await checkout.presentRedirectIfNeeded(for: result, using: presenter)
            listener.onOutcome(.completed(result))
            return
        }

        host.dispatch(.redirect)
        listener.onRequiresAction()
        do {
            switch try await checkout.presentRedirectIfNeeded(for: result, using: presenter) {
            case let .returned(url): listener.onOutcome(.returnedFromRedirect(url: url))
            case .canceled:
                host.dispatch(.cancelled)
                listener.onOutcome(.canceled)
            case nil: listener.onOutcome(.completed(result))  // the `onRedirection` hook took it over
            }
        } catch {
            listener.onOutcome(.failed(error.asPurseError()))
        }
    }
}
